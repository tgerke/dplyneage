# Connect two columns in a lineage diagram

Creates an edge from one table's column to another's, for diagrams built
with
[`create_table_node()`](https://tgerke.github.io/dplyneage/reference/create_table_node.md)
and rendered by
[`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md).
Table and column names must match the `table_name` and `columns` used
when creating the nodes.

## Usage

``` r
create_column_edge(
  from_table,
  from_column,
  to_table,
  to_column,
  label = NULL,
  animated = FALSE
)
```

## Arguments

- from_table, from_column:

  Table and column the data comes from.

- to_table, to_column:

  Table and column the data flows into.

- label:

  Optional label drawn on the edge, typically the transformation applied
  (e.g. `"SUM()"`).

- animated:

  If `TRUE`, the edge is drawn with a moving dash pattern. Useful for
  drawing attention to aggregations.

## Value

An edge list ready to pass to
[`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md)

## See also

Other manual lineage builders:
[`create_table_node()`](https://tgerke.github.io/dplyneage/reference/create_table_node.md),
[`lineage_example()`](https://tgerke.github.io/dplyneage/reference/lineage_example.md)

## Examples

``` r
# A direct column mapping
create_column_edge("customers", "id", "customer_summary", "customer_id")
#> $id
#> [1] "e_customers.id_to_customer_summary.customer_id"
#> 
#> $source
#> [1] "customers"
#> 
#> $target
#> [1] "customer_summary"
#> 
#> $sourceHandle
#> [1] "id"
#> 
#> $targetHandle
#> [1] "customer_id"
#> 
#> $animated
#> [1] FALSE
#> 
#> $style
#> $style$stroke
#> [1] "#64748b"
#> 
#> $style$strokeWidth
#> [1] 2
#> 
#> 

# An aggregation, labeled and animated
create_column_edge("orders", "amount", "customer_summary", "total_spent",
  label = "SUM()", animated = TRUE
)
#> $id
#> [1] "e_orders.amount_to_customer_summary.total_spent"
#> 
#> $source
#> [1] "orders"
#> 
#> $target
#> [1] "customer_summary"
#> 
#> $sourceHandle
#> [1] "amount"
#> 
#> $targetHandle
#> [1] "total_spent"
#> 
#> $animated
#> [1] TRUE
#> 
#> $style
#> $style$stroke
#> [1] "#64748b"
#> 
#> $style$strokeWidth
#> [1] 2
#> 
#> 
#> $label
#> [1] "SUM()"
#> 
#> $labelStyle
#> $labelStyle$fill
#> [1] "#64748b"
#> 
#> $labelStyle$fontWeight
#> [1] 500
#> 
#> $labelStyle$fontSize
#> [1] 11
#> 
#> 
#> $labelBgStyle
#> $labelBgStyle$fill
#> [1] "#ffffff"
#> 
#> $labelBgStyle$fillOpacity
#> [1] 0.9
#> 
#> 
```
