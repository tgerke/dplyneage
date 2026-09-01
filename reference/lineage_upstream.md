# Trace a column's ancestry or descendants

`lineage_upstream()` lists every column that feeds into `column`,
following edges transitively; `lineage_downstream()` lists every column
`column` feeds into. This is the core impact-analysis question ("what
breaks if this column changes?") answered directly on the lineage
object, without exporting to a graph tool. Passing a table name instead
of a column traces from every column of that table at once.

## Usage

``` r
lineage_upstream(lineage, column)

lineage_downstream(lineage, column)
```

## Arguments

- lineage:

  The result of
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md),
  or any list with `nodes` and `edges` built with
  [`create_table_node()`](https://tgerke.github.io/dplyneage/reference/create_table_node.md)
  and
  [`create_column_edge()`](https://tgerke.github.io/dplyneage/reference/create_column_edge.md).

- column:

  A `"table.column"` string identifying the column to trace from, e.g.
  `"output.total_spent"`, or a table name to trace from all of that
  table's columns. Names are matched exactly, never split on dots; a
  string that is both a column key and a schema-qualified table name (a
  node `"main"` with column `"silver"` alongside a node `"main.silver"`)
  is read as the column key.

## Value

A character vector of `"table.column"` identifiers, sorted. Empty when
the column has no upstream (or downstream) connections. For a table, the
table's own columns are not part of the answer.

## See also

Other lineage accessors:
[`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md),
[`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md),
[`lineage_edges()`](https://tgerke.github.io/dplyneage/reference/lineage_edges.md),
[`lineage_tables()`](https://tgerke.github.io/dplyneage/reference/lineage_tables.md),
[`lineage_unused()`](https://tgerke.github.io/dplyneage/reference/lineage_unused.md)

## Examples

``` r
lineage <- list(
  nodes = list(
    create_table_node("orders", "amount"),
    create_table_node("daily_totals", "total", table_type = "target")
  ),
  edges = list(
    create_column_edge("orders", "amount", "daily_totals", "total")
  )
)
lineage_upstream(lineage, "daily_totals.total")
#> [1] "orders.amount"
lineage_downstream(lineage, "orders.amount")
#> [1] "daily_totals.total"
lineage_downstream(lineage, "orders")
#> [1] "daily_totals.total"
```
