# Export lineage as an OpenLineage run event

Serializes a lineage object to an [OpenLineage](https://openlineage.io/)
`RunEvent` JSON document with a `ColumnLineage` facet on each output
dataset — the interchange format that data catalogs and lineage backends
(Marquez, DataHub, OpenMetadata, ...) ingest. POST the document to an
OpenLineage endpoint and dplyneage-extracted lineage appears alongside
lineage from dbt, Airflow, or Spark.

## Usage

``` r
lineage_openlineage(
  lineage,
  path = NULL,
  namespace = "dplyneage",
  job_name = "extract_lineage",
  run_id = NULL,
  event_time = NULL,
  pretty = TRUE
)
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

- namespace:

  Dataset and job namespace recorded in the event. OpenLineage uses
  namespaces to group datasets by system; the default `"dplyneage"` is
  fine for standalone use, but match your catalog's namespace when
  integrating.

- job_name:

  Name recorded for the job that produced this lineage.

- run_id:

  UUID identifying the run. Generated when `NULL` (the default); pass a
  fixed UUID for reproducible output.

- event_time:

  Event timestamp in ISO-8601 format. The current UTC time when `NULL`
  (the default); pass a fixed timestamp for reproducible output.

- pretty:

  If `TRUE` (the default), indent the output for readability. Use
  `FALSE` for a single-line document.

## Value

A JSON string containing one OpenLineage `RunEvent` of type `COMPLETE`.

## Details

Source tables become the event's `inputs` (with a schema facet listing
their referenced columns); transform and target tables become `outputs`,
each carrying a `columnLineage` facet that maps every output column to
its input fields. Edge classifications translate to OpenLineage
transformation types: `identity`/`transformation`/ `aggregation` edges
become `DIRECT` transformations with the matching subtype, and indirect
edges (from `extract_lineage(include_indirect = TRUE)`) become
`INDIRECT` with subtype `FILTER`, `JOIN`, `GROUP_BY`, or `SORT`. A
direct edge's defining expression is carried in the transformation's
`description`.

## See also

[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
to compute lineage automatically

Other lineage exporters:
[`lineage_graphml()`](https://tgerke.github.io/dplyneage/reference/lineage_graphml.md),
[`lineage_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md),
[`lineage_mermaid()`](https://tgerke.github.io/dplyneage/reference/lineage_mermaid.md)

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
lineage_openlineage(
  lineage,
  run_id = "00000000-0000-4000-8000-000000000000",
  event_time = "2026-01-01T00:00:00.000Z"
)
#> {
#>   "eventType": "COMPLETE",
#>   "eventTime": "2026-01-01T00:00:00.000Z",
#>   "run": {
#>     "runId": "00000000-0000-4000-8000-000000000000"
#>   },
#>   "job": {
#>     "namespace": "dplyneage",
#>     "name": "extract_lineage"
#>   },
#>   "inputs": [
#>     {
#>       "namespace": "dplyneage",
#>       "name": "orders",
#>       "facets": {
#>         "schema": {
#>           "_producer": "https://github.com/tgerke/dplyneage",
#>           "_schemaURL": "https://openlineage.io/spec/facets/1-1-1/SchemaDatasetFacet.json",
#>           "fields": [
#>             {
#>               "name": "order_id"
#>             },
#>             {
#>               "name": "amount"
#>             }
#>           ]
#>         }
#>       }
#>     }
#>   ],
#>   "outputs": [
#>     {
#>       "namespace": "dplyneage",
#>       "name": "daily_totals",
#>       "facets": {
#>         "schema": {
#>           "_producer": "https://github.com/tgerke/dplyneage",
#>           "_schemaURL": "https://openlineage.io/spec/facets/1-1-1/SchemaDatasetFacet.json",
#>           "fields": [
#>             {
#>               "name": "total"
#>             }
#>           ]
#>         },
#>         "columnLineage": {
#>           "_producer": "https://github.com/tgerke/dplyneage",
#>           "_schemaURL": "https://openlineage.io/spec/facets/1-2-0/ColumnLineageDatasetFacet.json",
#>           "fields": {
#>             "total": {
#>               "inputFields": [
#>                 {
#>                   "namespace": "dplyneage",
#>                   "name": "orders",
#>                   "field": "amount"
#>                 }
#>               ]
#>             }
#>           }
#>         }
#>       }
#>     }
#>   ],
#>   "producer": "https://github.com/tgerke/dplyneage",
#>   "schemaURL": "https://openlineage.io/spec/2-0-2/OpenLineage.json#/definitions/RunEvent"
#> } 
```
