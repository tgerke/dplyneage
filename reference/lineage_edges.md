# Lineage edges as a data frame

Flattens a lineage object's column-level edges into one row per edge,
for filtering, joining, and summarising with ordinary data frame tools.
For edges produced by
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md),
the `transformation` column classifies each edge (`"identity"` for plain
column passthrough, `"aggregation"`, or `"transformation"`) and
`expression` records the output column's defining expression; both are
`NA` for hand-built edges. With `include_indirect = TRUE`, indirect
edges are classified by how the source column is used — `"filter"`,
`"join"`, `"group_by"`, or `"sort"` — with `NA` for `expression`.

## Usage

``` r
lineage_edges(lineage)
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

A data frame with columns `source_table`, `source_column`,
`target_table`, `target_column`, `transformation`, and `expression`.

## See also

Other lineage accessors:
[`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md),
[`lineage_tables()`](https://tgerke.github.io/dplyneage/reference/lineage_tables.md),
[`lineage_upstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)

## Examples

``` r
lineage <- list(
  nodes = list(
    create_table_node("orders", c("order_id", "amount")),
    create_table_node("daily_totals", "total", table_type = "target")
  ),
  edges = list(
    create_column_edge("orders", "amount", "daily_totals", "total")
  )
)
lineage_edges(lineage)
#>   source_table source_column target_table target_column transformation
#> 1       orders        amount daily_totals         total           <NA>
#>   expression
#> 1       <NA>
```
