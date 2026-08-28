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

A JSON string; see the Document shape section.

## Document shape

The top-level keys, in order:

- `format_version`: integer version of this document shape, currently

  1.  It bumps only when a change would break an existing consumer;
      added fields do not bump it.

- `metadata`: present on
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  results. Carries `dialect`, `engine`, `models`, `node_count`, and
  `edge_count`. `models` maps each model name to its `sql`, `engine`,
  and `dialect`; a single-query extraction is a one-model map keyed by
  the output table's name, so consumers read per-model SQL the same way
  for both shapes. A model extracted from a table on a live database
  connection also carries `namespace`, the OpenLineage namespace URI
  inferred from that connection. The top-level `dialect` and `engine`
  collapse across models, to `"mixed"` when models disagree.

- `nodes`: objects with `id`, `type` (`"source"`, `"transform"`, or
  `"target"`), and `columns`. A source node whose column types were
  captured (from a live connection's schema, or a typed `schema`
  argument) also carries `types`, a column-to-type map covering the
  typed subset of its columns.

- `edges`: objects with `source`, `source_column`, `target`, and
  `target_column`. Edges from
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  also carry `transformation` and, on direct edges, `expression`. An
  indirect edge whose column shapes the result in several ways (filtered
  and sorted on, say) adds `transformations`, the full set of kinds with
  the first one leading.

## See also

[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
to compute lineage automatically

Other lineage exporters:
[`lineage_emit()`](https://tgerke.github.io/dplyneage/reference/lineage_emit.md),
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
#>   "format_version": 1,
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
#>   "format_version": 1,
#>   "metadata": {
#>     "dialect": "duckdb",
#>     "engine": "sqlglot",
#>     "models": {
#>       "output": {
#>         "sql": "SELECT customer_id, SUM(amount) AS total\n                 FROM orders GROUP BY customer_id",
#>         "engine": "sqlglot",
#>         "dialect": "duckdb"
#>       }
#>     },
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
