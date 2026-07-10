"""Column-level lineage extraction for dplyneage.

Built on sqlglot's purpose-built lineage module, which handles scope
resolution, alias expansion, CTE trace-through, set operations, and
(given a schema) star expansion and unqualified column attribution.
"""

from sqlglot import exp, parse_one
from sqlglot.errors import SqlglotError
from sqlglot.lineage import lineage
from sqlglot.optimizer.qualify import qualify


def _table_name(table):
    """Qualified table name: catalog.db.name for whichever parts exist."""
    return ".".join(part.name for part in table.parts if part.name)


def _normalize_schema(schema):
    """Accept {table: [col, ...]} or {table: {col: type}}, with optionally
    qualified table keys ("db.table"); return (nested sqlglot schema, warning).

    sqlglot's MappingSchema requires every table at the same nesting depth,
    so a schema mixing qualified and unqualified names is dropped with a
    warning rather than raising mid-extraction.
    """
    if not schema:
        return None, None
    depths = set()
    entries = []
    for table, cols in schema.items():
        if isinstance(cols, dict):
            coldict = cols
        else:
            if isinstance(cols, str):
                cols = [cols]
            coldict = {str(col): "unknown" for col in cols}
        parts = str(table).split(".")
        depths.add(len(parts))
        entries.append((parts, coldict))
    if len(depths) > 1:
        return None, (
            "Schema mixes qualified and unqualified table names; sqlglot "
            "needs a uniform nesting depth, so the schema was ignored."
        )
    nested = {}
    for parts, coldict in entries:
        node = nested
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node[parts[-1]] = coldict
    return (nested or None), None


def _cte_names(expression):
    return {cte.alias_or_name for cte in expression.find_all(exp.CTE)}


def list_tables(sql, dialect="duckdb"):
    """Return base (non-CTE) table references in a SQL query."""
    parsed = parse_one(sql, dialect=dialect)
    ctes = _cte_names(parsed)
    tables = []
    seen = set()
    for table in parsed.find_all(exp.Table):
        name = _table_name(table)
        # CTE references are always unqualified, so bare-name matching holds
        if table.name in ctes or name in seen:
            continue
        seen.add(name)
        tables.append(
            {
                "name": name,
                "alias": table.alias or None,
                "qualified_name": table.sql(dialect=dialect),
            }
        )
    return tables


def _leaves(node):
    if not node.downstream:
        yield node
    for child in node.downstream:
        yield from _leaves(child)


def _column_sources(column, sql, schema, dialect):
    """Trace one output column to its base-table source columns."""
    node = lineage(column, sql, schema=schema, dialect=dialect)
    sources = []
    seen = set()
    for leaf in _leaves(node):
        # Leaves whose source is not a real table (e.g. literals, values
        # clauses) contribute no lineage edge.
        if not isinstance(leaf.source, exp.Table):
            continue
        table = _table_name(leaf.source)
        col = leaf.name.split(".")[-1]
        key = (table, col)
        if key not in seen:
            seen.add(key)
            sources.append({"table": table, "column_name": col})
    return sources


def _select_info(expression, dialect):
    """Map each output column name to its defining expression SQL and a
    coarse lineage classification (identity / aggregation / transformation),
    mirroring OpenLineage's transformation types."""
    try:
        selects = expression.selects
    except Exception:
        return {}
    info = {}
    for select in selects:
        inner = select.this if isinstance(select, exp.Alias) else select
        if isinstance(inner, exp.Column):
            kind = "identity"
        elif inner.find(exp.AggFunc):
            kind = "aggregation"
        else:
            kind = "transformation"
        info[select.alias_or_name] = {
            "expression": inner.sql(dialect=dialect),
            "type": kind,
        }
    return info


def _indirect_refs(qualified, dialect):
    """Columns referenced in WHERE/HAVING/JOIN ON/GROUP BY/ORDER BY.

    These shape the result without appearing in it (OpenLineage's
    "indirect" lineage). Works on the qualified tree so column references
    carry a table alias; the alias map covers every table in the tree, so
    filters inside CTE bodies attribute to their base tables. Columns that
    resolve to a CTE itself (an outer query filtering on a CTE output) are
    skipped rather than mis-attributed.
    """
    ctes = _cte_names(qualified)
    alias_to_table = {}
    for table in qualified.find_all(exp.Table):
        name = _table_name(table)
        alias_to_table[table.alias_or_name] = name
        alias_to_table.setdefault(name, name)

    containers = []
    for where in qualified.find_all(exp.Where):
        containers.append((where, "filter"))
    for having in qualified.find_all(exp.Having):
        containers.append((having, "filter"))
    for group in qualified.find_all(exp.Group):
        containers.append((group, "group_by"))
    for order in qualified.find_all(exp.Order):
        containers.append((order, "sort"))
    for join in qualified.find_all(exp.Join):
        on = join.args.get("on")
        if on is not None:
            containers.append((on, "join"))

    refs = []
    seen = set()
    for node, kind in containers:
        for col in node.find_all(exp.Column):
            table = alias_to_table.get(col.table)
            if not table or col.table in ctes or table in ctes:
                continue
            key = (table, col.name, kind)
            if key in seen:
                continue
            seen.add(key)
            refs.append({"table": table, "column_name": col.name, "kind": kind})
    return refs


def extract_lineage(sql, dialect="duckdb", schema=None, include_indirect=False):
    """Extract column-level lineage from a SQL query.

    Returns a dict with:
      tables:   base table references
      columns:  [{output_name, expression, sources: [{table, column_name}]}]
      warnings: human-readable notes about anything that could not be traced
      indirect: (only with include_indirect) [{table, column_name, kind}]
    """
    schema, schema_warning = _normalize_schema(schema)
    parsed = parse_one(sql, dialect=dialect)
    warnings = []
    if schema_warning:
        warnings.append(schema_warning)

    # Qualify (with schema when available) so stars expand and unqualified
    # columns resolve to their tables. Fall back to the raw parse on failure.
    try:
        qualified = qualify(
            parsed.copy(),
            schema=schema,
            dialect=dialect,
            validate_qualify_columns=False,
        )
    except SqlglotError as err:
        warnings.append(f"Could not fully qualify query: {err}")
        qualified = parsed

    output_names = qualified.named_selects
    if "*" in output_names:
        output_names = [name for name in output_names if name != "*"]
        warnings.append(
            "Query selects '*' but no schema is available to expand it; "
            "starred columns are omitted. Pass a dbplyr table or supply "
            "`schema` to expand them."
        )

    # Prefer the expression as written; star-expanded columns only exist in
    # the qualified tree
    info = _select_info(qualified, dialect)
    info.update(_select_info(parsed, dialect))

    columns = []
    for name in output_names:
        details = info.get(name, {"expression": name, "type": None})
        col_info = {
            "output_name": name,
            "expression": details["expression"],
            "type": details["type"],
            "sources": [],
        }
        try:
            col_info["sources"] = _column_sources(name, sql, schema, dialect)
        except SqlglotError as err:
            warnings.append(f"Could not trace column '{name}': {err}")
        columns.append(col_info)

    result = {
        "tables": list_tables(sql, dialect=dialect),
        "columns": columns,
        "warnings": warnings,
    }
    if include_indirect:
        result["indirect"] = _indirect_refs(qualified, dialect)
    return result
