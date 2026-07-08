"""Column-level lineage extraction for dplyneage.

Built on sqlglot's purpose-built lineage module, which handles scope
resolution, alias expansion, CTE trace-through, set operations, and
(given a schema) star expansion and unqualified column attribution.
"""

from sqlglot import exp, parse_one
from sqlglot.errors import SqlglotError
from sqlglot.lineage import lineage
from sqlglot.optimizer.qualify import qualify


def _normalize_schema(schema):
    """Accept {table: [col, ...]} or {table: {col: type}}; return sqlglot form."""
    if not schema:
        return None
    normalized = {}
    for table, cols in schema.items():
        if isinstance(cols, dict):
            normalized[table] = cols
        else:
            if isinstance(cols, str):
                cols = [cols]
            normalized[table] = {str(col): "unknown" for col in cols}
    return normalized or None


def _cte_names(expression):
    return {cte.alias_or_name for cte in expression.find_all(exp.CTE)}


def list_tables(sql, dialect="duckdb"):
    """Return base (non-CTE) table references in a SQL query."""
    parsed = parse_one(sql, dialect=dialect)
    ctes = _cte_names(parsed)
    tables = []
    seen = set()
    for table in parsed.find_all(exp.Table):
        name = table.name
        if name in ctes or name in seen:
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
        table = leaf.source.name
        col = leaf.name.split(".")[-1]
        key = (table, col)
        if key not in seen:
            seen.add(key)
            sources.append({"table": table, "column_name": col})
    return sources


def extract_lineage(sql, dialect="duckdb", schema=None):
    """Extract column-level lineage from a SQL query.

    Returns a dict with:
      tables:   base table references
      columns:  [{output_name, expression, sources: [{table, column_name}]}]
      warnings: human-readable notes about anything that could not be traced
    """
    schema = _normalize_schema(schema)
    parsed = parse_one(sql, dialect=dialect)
    warnings = []

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

    columns = []
    for name in output_names:
        col_info = {"output_name": name, "expression": name, "sources": []}
        try:
            col_info["sources"] = _column_sources(name, sql, schema, dialect)
        except SqlglotError as err:
            warnings.append(f"Could not trace column '{name}': {err}")
        columns.append(col_info)

    return {
        "tables": list_tables(sql, dialect=dialect),
        "columns": columns,
        "warnings": warnings,
    }
