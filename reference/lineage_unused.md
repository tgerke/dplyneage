# Report columns with no path to any target

The dead-column report: every column on a source or transform table from
which no chain of edges reaches a target table. In a multi-model lineage
that surfaces base-table columns nothing reads and intermediate-model
outputs no downstream model consumes, both safe to drop as far as the
graph can see.

## Usage

``` r
lineage_unused(lineage)
```

## Arguments

- lineage:

  The result of
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md),
  or any list with `nodes` and `edges` built with
  [`create_table_node()`](https://tgerke.github.io/dplyneage/reference/create_table_node.md)
  and
  [`create_column_edge()`](https://tgerke.github.io/dplyneage/reference/create_column_edge.md).

## Value

A data frame with columns `table`, `column`, and `table_type`, one row
per unused column, sorted by table then column. Zero rows when every
column reaches a target.

## Details

A single-query extraction usually reports nothing, because its source
nodes only carry columns the query referenced. Tables whose type is
unknown (hand-built nodes without a `table_type`) count as targets, on
the same reasoning as
[`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md)
severity: the graph cannot see who consumes them, so their columns, and
columns feeding them, are not called unused.

## See also

Other lineage accessors:
[`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md),
[`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md),
[`lineage_edges()`](https://tgerke.github.io/dplyneage/reference/lineage_edges.md),
[`lineage_tables()`](https://tgerke.github.io/dplyneage/reference/lineage_tables.md),
[`lineage_upstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)

## Examples

``` r
lineage <- list(
  nodes = list(
    create_table_node("orders", c("order_id", "amount", "internal_note")),
    create_table_node("daily_totals", "total", table_type = "target")
  ),
  edges = list(
    create_column_edge("orders", "amount", "daily_totals", "total")
  )
)
lineage_unused(lineage)
#>    table        column table_type
#> 1 orders internal_note     source
#> 2 orders      order_id     source
```
