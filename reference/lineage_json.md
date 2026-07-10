# Export lineage as JSON

Serializes a lineage object to a small, stable JSON document: node ids
with their columns and table type, plus one record per column-level
edge. React Flow presentation details (positions, colors) are
deliberately dropped, so the output is suitable for scripting with jq,
committing to version control (a CI diff catches accidental provenance
changes when a pipeline is edited), or feeding to a data catalog.

## Usage

``` r
lineage_json(lineage, path = NULL, pretty = TRUE)
```

## Arguments

- lineage:

  The result of
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md),
  or any list with `nodes` and `edges` built with
  [`create_table_node()`](https://tgerke.github.io/dplyneage/reference/create_table_node.md)
  and
  [`create_column_edge()`](https://tgerke.github.io/dplyneage/reference/create_column_edge.md).

- path:

  Optional file to write the JSON to. When supplied, the string is
  returned invisibly.

- pretty:

  If `TRUE` (the default), indent the output for readability. Use
  `FALSE` for a single-line document.

## Value

A JSON string. With `metadata` (present on
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
results), `nodes` (objects with `id`, `type`, and `columns`), and
`edges` (objects with `source`, `source_column`, `target`, and
`target_column`; edges produced by
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
also carry `transformation` and `expression`).

## See also

[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
to compute lineage automatically

Other lineage exporters:
[`lineage_graphml()`](https://tgerke.github.io/dplyneage/reference/lineage_graphml.md),
[`lineage_mermaid()`](https://tgerke.github.io/dplyneage/reference/lineage_mermaid.md),
[`lineage_openlineage()`](https://tgerke.github.io/dplyneage/reference/lineage_openlineage.md)

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
lineage_json(lineage)
#> {
#>   "nodes": [
#>     {
#>       "id": "orders",
#>       "type": "source",
#>       "columns": ["order_id", "amount"]
#>     },
#>     {
#>       "id": "daily_totals",
#>       "type": "target",
#>       "columns": ["total"]
#>     }
#>   ],
#>   "edges": [
#>     {
#>       "source": "orders",
#>       "source_column": "amount",
#>       "target": "daily_totals",
#>       "target_column": "total"
#>     }
#>   ]
#> } 

# Write to a file instead
path <- tempfile(fileext = ".json")
lineage_json(lineage, path = path)
extract_lineage("SELECT customer_id, SUM(amount) AS total
                 FROM orders GROUP BY customer_id") |>
  lineage_json()
#> {
#>   "metadata": {
#>     "sql": "SELECT customer_id, SUM(amount) AS total\n                 FROM orders GROUP BY customer_id",
#>     "dialect": "duckdb",
#>     "engine": "sqlglot",
#>     "node_count": 2,
#>     "edge_count": 2
#>   },
#>   "nodes": [
#>     {
#>       "id": "orders",
#>       "type": "source",
#>       "columns": ["customer_id", "amount"]
#>     },
#>     {
#>       "id": "output",
#>       "type": "target",
#>       "columns": ["customer_id", "total"]
#>     }
#>   ],
#>   "edges": [
#>     {
#>       "source": "orders",
#>       "source_column": "customer_id",
#>       "target": "output",
#>       "target_column": "customer_id",
#>       "transformation": "identity",
#>       "expression": "customer_id"
#>     },
#>     {
#>       "source": "orders",
#>       "source_column": "amount",
#>       "target": "output",
#>       "target_column": "total",
#>       "transformation": "aggregation",
#>       "expression": "SUM(amount)"
#>     }
#>   ]
#> } 
```
