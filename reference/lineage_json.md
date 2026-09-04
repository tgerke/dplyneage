# Export lineage as JSON, and read it back

Serializes a lineage object to a small, stable JSON document: node ids
with their columns and table type, plus one record per column-level
edge. React Flow presentation details (positions, colors) are
deliberately dropped, so the output is suitable for scripting with jq,
committing to version control (a CI diff catches accidental provenance
changes when a pipeline is edited), or feeding to a data catalog.

## Usage

``` r
lineage_json(lineage, path = NULL, pretty = TRUE)

lineage_from_json(x)
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

- x:

  The document to read: a JSON string as `lineage_json()` returns it, or
  the path to a file it wrote.

## Value

`lineage_json()` returns a JSON string; see the Document shape section.
`lineage_from_json()` returns a lineage object (class
`dplyneage_lineage`) with `nodes`, `edges`, and, when the document
carries it, `metadata`.

## Details

`lineage_from_json()` reads that document back into a lineage object,
rebuilding the nodes and edges every accessor and exporter works on. A
committed artifact can then stand in for a fresh extraction as the `old`
side of
[`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md)
or
[`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md),
and lineage kept in a catalog or a database row comes back for
[`lineage_upstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)
and the exports.

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
  `"target"`), and `columns`. A node whose columns carry types (from a
  live connection's schema, or a typed `schema` argument) adds `types`,
  a column-to-type map over that subset; one whose columns carry labels
  (`label` attributes on a local frame, database column comments, or a
  `labels` argument) adds `labels`, shaped the same way. Both spread
  along identity edges, so a passthrough column reports its source
  column's type and label.

- `edges`: objects with `source`, `source_column`, `target`, and
  `target_column`. Edges from
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  also carry `transformation` and, on direct edges, `expression`. An
  indirect edge whose column shapes the result in several ways (filtered
  and sorted on, say) adds `transformations`, the full set of kinds with
  the first one leading.

`lineage_from_json()` rebuilds a lineage object from these fields. Node
positions and edge labels are recomputed by the layout rules rather than
restored, and the `label` and `animated` settings of a hand-built edge
do not come back, since the document never carried them.

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

# Read it back: the rebuilt lineage feeds every accessor and exporter
lineage_diff(lineage, lineage_from_json(path))
#> No lineage changes.
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
