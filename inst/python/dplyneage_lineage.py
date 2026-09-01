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
        # A file-path table ("/data/orders.csv") is one identifier: its
        # dots are not db.table qualification
        name = str(table)
        parts = [name] if "/" in name or "\\" in name else name.split(".")
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


def _node_sources(node, dialect):
    """Collect the base-table source columns under a lineage node."""
    sources = []
    seen = set()
    for leaf in _leaves(node):
        # Leaves whose source is not a real table (e.g. literals, values
        # clauses) contribute no lineage edge.
        if not isinstance(leaf.source, exp.Table):
            continue
        table = _table_name(leaf.source)
        # leaf.name renders the column as a SQL identifier, which keeps
        # dialect quoting ('orders."amount"') on dialects where sqlglot
        # won't normalize it away; parse rather than split on "."
        try:
            col = exp.to_column(leaf.name, dialect=dialect).name
        except SqlglotError:
            col = leaf.name.split(".")[-1]
        key = (table, col)
        if key not in seen:
            seen.add(key)
            sources.append({"table": table, "column_name": col})
    return sources


_KIND_RANK = {"identity": 0, "transformation": 1, "aggregation": 2}


def _classify(expr):
    """Coarse kind of one select expression (identity / aggregation /
    transformation), mirroring OpenLineage's transformation types."""
    if isinstance(expr, exp.Column):
        return "identity"
    if expr.find(exp.AggFunc):
        return "aggregation"
    return "transformation"


def _select_info(expression, dialect):
    """Map each output column name to its defining expression SQL and its
    kind, read from the outermost select list as written."""
    try:
        selects = expression.selects
    except Exception:
        return {}
    info = {}
    for select in selects:
        inner = select.this if isinstance(select, exp.Alias) else select
        info[select.alias_or_name] = {
            "expression": inner.sql(dialect=dialect),
            "type": _classify(inner),
        }
    return info


def _hop_expression(node):
    expr = node.expression
    return expr.this if isinstance(expr, exp.Alias) else expr


def _computes(node):
    """Does this lineage hop compute something?

    to_node() gives every real select-item hop a trimmed Select as its
    `source`. Set-operation roots carry the SetOperation instead (their
    `expression` is only the left branch's item), and leaves plus star
    children have `expression is source` (a Table, a derived Select, a
    Values, a Placeholder). Those all pass through; a select item that
    is not a bare column or star computes.
    """
    if node.expression is node.source or not isinstance(node.source, exp.Select):
        return False
    expr = _hop_expression(node)
    return not isinstance(
        expr, (exp.Column, exp.Star, exp.Select, exp.SetOperation)
    )


def _unqualified_sql(expr, dialect):
    """Render without table qualifiers so inner-hop labels read like the
    as-written outer ones. transform() copies; the Node tree is untouched."""
    return expr.transform(
        lambda n: exp.column(n.this) if isinstance(n, exp.Column) else n
    ).sql(dialect=dialect)


def _computed_kind(node, dialect):
    """(kind, expression) of the outermost hop below `node` that computes.

    Design rule, chosen to match dplyneage's R walkers rather than
    inherited from sqlglot: identity hops are transparent, so a column
    that passes unchanged through outer projections (dbplyr's nested
    selects for chained mutates, duckplyr's SELECT * wrappers, a CTE read
    back by name) keeps the kind and expression of the hop that computed
    it. Across set-operation branches, aggregation outranks
    transformation. None when every hop passes through.
    """
    best = None
    for child in node.downstream:
        if _computes(child):
            expr = _hop_expression(child)
            found = (_classify(expr), _unqualified_sql(expr, dialect))
        else:
            found = _computed_kind(child, dialect)
        if found and (best is None or _KIND_RANK[found[0]] > _KIND_RANK[best[0]]):
            best = found
    return best


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
        # ORDER BY inside WITHIN GROUP (ordered-set aggregates such as
        # percentile_cont) is an argument of the aggregate, not a result
        # ordering; lineage() already reports the column as a direct source.
        if order.find_ancestor(exp.WithinGroup):
            continue
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
            node = lineage(name, sql, schema=schema, dialect=dialect)
        except SqlglotError as err:
            warnings.append(f"Could not trace column '{name}': {err}")
        else:
            col_info["sources"] = _node_sources(node, dialect)
            # A root that only passes a column through (or a set-operation
            # root) takes the kind of the outermost hop that computed it
            if not _computes(node):
                computed = _computed_kind(node, dialect)
                if computed:
                    col_info["type"], col_info["expression"] = computed
        columns.append(col_info)

    result = {
        "tables": list_tables(sql, dialect=dialect),
        "columns": columns,
        "warnings": warnings,
    }
    if include_indirect:
        result["indirect"] = _indirect_refs(qualified, dialect)
    return result
