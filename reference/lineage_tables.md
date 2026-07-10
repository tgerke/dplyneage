# Lineage tables as a data frame

Summarises a lineage object's nodes: one row per table with its diagram
role and column count.

## Usage

``` r
lineage_tables(lineage)
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

A data frame with columns `table`, `type` (`"source"`, `"transform"`, or
`"target"`), and `n_columns`.

## See also

Other lineage accessors:
[`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md),
[`lineage_edges()`](https://tgerke.github.io/dplyneage/reference/lineage_edges.md),
[`lineage_upstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)

## Examples

``` r
lineage <- list(
  nodes = list(
    create_table_node("orders", c("order_id", "amount")),
    create_table_node("daily_totals", "total", table_type = "target")
  ),
  edges = list()
)
lineage_tables(lineage)
#>          table   type n_columns
#> 1       orders source         2
#> 2 daily_totals target         1
```
