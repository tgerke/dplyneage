# Compare two lineage extractions

Reports the column-level edges and table columns that were added or
removed between two lineage objects — typically the same pipeline before
and after an edit. This makes the CI story concrete: extract lineage on
both branches and fail (or comment) when provenance changed.

## Usage

``` r
lineage_diff(old, new)
```

## Arguments

- old, new:

  Lineage objects from
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  (or lists with `nodes` and `edges`), in before/after order.

## Value

A `dplyneage_lineage_diff` list with data frame elements `added_edges`,
`removed_edges`, `added_columns`, and `removed_columns`. Its print
method summarises the changes; zero-row elements mean no change.

## See also

Other lineage accessors:
[`lineage_edges()`](https://tgerke.github.io/dplyneage/reference/lineage_edges.md),
[`lineage_tables()`](https://tgerke.github.io/dplyneage/reference/lineage_tables.md),
[`lineage_upstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)

## Examples

``` r
old <- list(
  nodes = list(
    create_table_node("orders", "amount"),
    create_table_node("out", "total", table_type = "target")
  ),
  edges = list(create_column_edge("orders", "amount", "out", "total"))
)
new <- list(
  nodes = list(
    create_table_node("orders", c("amount", "tax")),
    create_table_node("out", "total", table_type = "target")
  ),
  edges = list(
    create_column_edge("orders", "amount", "out", "total"),
    create_column_edge("orders", "tax", "out", "total")
  )
)
lineage_diff(old, new)
#> <dplyneage lineage diff>
#> Added edges:
#>   + orders.tax -> out.total
#> Added columns:
#>   + orders.tax
```
