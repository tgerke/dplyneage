# Export lineage as OpenLineage events

Serializes a lineage object to [OpenLineage](https://openlineage.io/)
JSON — the interchange format that data catalogs and lineage backends
(Marquez, DataHub, OpenMetadata, ...) ingest. The default is one
`RunEvent` with a `ColumnLineage` facet on each output dataset; POST it
to an OpenLineage endpoint (see
[`lineage_emit()`](https://tgerke.github.io/dplyneage/reference/lineage_emit.md))
and dplyneage-extracted lineage appears alongside lineage from dbt,
Airflow, or Spark.

## Usage

``` r
lineage_openlineage(
  lineage,
  path = NULL,
  namespace = NULL,
  job_name = "extract_lineage",
  run_id = NULL,
  event_time = NULL,
  pretty = TRUE,
  events = "run",
  event_type = "COMPLETE",
  output_name = NULL,
  nominal_time = NULL,
  parent = NULL
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

  Dataset and job namespace recorded in the event. The default `NULL`
  resolves each dataset's namespace from the connection captured at
  extraction time (see the Namespaces section); pass a string to
  override everything, matching your catalog's namespace when
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

- events:

  Which event kinds to emit: any combination of `"run"` (the default;
  one `RunEvent` for the whole extraction), `"job"` (run-less
  `JobEvent`s, one per model), and `"dataset"` (run-less
  `DatasetEvent`s, one per dataset). See the Static lineage events
  section.

- event_type:

  The run state a `"run"` event reports: `"COMPLETE"` (the default),
  `"START"`, `"RUNNING"`, `"ABORT"`, `"FAIL"`, or `"OTHER"`. Static
  events carry no run state.

- output_name:

  Name recorded for the output dataset in place of the synthetic
  `"output"` node id of a single-query extraction — use it when the
  query's result lands in a known table. Errors on multi-model lineage,
  whose models already carry their real names.

- nominal_time:

  One or two ISO-8601 timestamps — the scheduled `nominalStartTime` and
  optionally `nominalEndTime` — emitted as the `nominalTime` run facet.
  `NULL` (the default) omits the facet.

- parent:

  A `list(run_id = , job_name = )`, optionally with a `namespace`,
  identifying the orchestrating run this event belongs under (an Airflow
  task, a dbt run); emitted as the `parent` run facet. `NULL` (the
  default) omits the facet.

## Value

A JSON string: one indented event document, or NDJSON with one event per
line (see the Static lineage events section for when each applies).

## Static lineage events

dplyneage extracts lineage from code without running it, which is the
case OpenLineage defines run-less events for. `events = "job"` emits one
`JobEvent` per model — its job named after the model, its inputs the
datasets the model reads (upstream models included), its output carrying
the `columnLineage` facet — and `events = "dataset"` emits one
`DatasetEvent` per dataset, sources included, as a static schema
registration. Both carry no `run`, so no run has to be fabricated for
design-time lineage. Kinds combine: `events = c("job", "dataset")` emits
both sets in one document.

When the selection yields a single event and `pretty = TRUE`, the result
is one indented JSON document. Anything else — several events, or
`pretty = FALSE` — is NDJSON, one compact event per line, the format
OpenLineage's `FileTransport` writes and replay tooling reads: a
committed events file can later be replayed into any backend.

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

## Namespaces

OpenLineage groups datasets by namespace, and catalogs join events to
known datasets through it, so the spec expects scheme URIs derived from
the data store (`postgres://host:port`, `mysql://host:port`).
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
captures that URI from the table's live connection — `duckdb:<path>` and
`sqlite:<path>` for file-backed databases (bare `duckdb`/`sqlite` in
memory, since the spec names no convention for either), the spec's
host:port form for server databases — and each dataset in the event uses
the namespace captured for its model. A URI-shaped namespace is also
recorded in the dataset's `dataSource` facet. Where nothing was captured
(local frames via
[`dbplyr::tbl_lazy()`](https://dbplyr.tidyverse.org/reference/tbl_lazy.html),
hand-built graphs, unrecognized drivers), datasets fall back to
`"dplyneage"`. The job namespace is always `"dplyneage"`: OpenLineage
job namespaces identify the producer, not the data store. Passing an
explicit `namespace` overrides all of this, for datasets and job alike.

## Facets

Beyond `schema`, `dataSource`, and `columnLineage` on datasets, the
event carries job facets: `jobType` (`BATCH`/`DPLYNEAGE`/`QUERY`) and,
for single-model lineage, `sql` with the analyzed query and its dialect.
Schema facet fields include a `type` when column types were captured —
from a live connection's tables, or a `schema` argument with named
entries like `list(orders = list(amount = "DOUBLE"))`. Indirect edges
land in the `columnLineage` facet's dataset-level `dataset` array rather
than under individual output columns: filter, join, group and sort
columns shape the whole result, which is exactly what that array
expresses. Optional run facets (`nominalTime`, `parent`) attach through
the matching arguments.

## See also

[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
to compute lineage automatically

Other lineage exporters:
[`lineage_emit()`](https://tgerke.github.io/dplyneage/reference/lineage_emit.md),
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
#>     "name": "extract_lineage",
#>     "facets": {
#>       "jobType": {
#>         "_producer": "https://github.com/tgerke/dplyneage",
#>         "_schemaURL": "https://openlineage.io/spec/facets/2-0-4/JobTypeJobFacet.json#/$defs/JobTypeJobFacet",
#>         "processingType": "BATCH",
#>         "integration": "DPLYNEAGE",
#>         "jobType": "QUERY"
#>       }
#>     }
#>   },
#>   "inputs": [
#>     {
#>       "namespace": "dplyneage",
#>       "name": "orders",
#>       "facets": {
#>         "schema": {
#>           "_producer": "https://github.com/tgerke/dplyneage",
#>           "_schemaURL": "https://openlineage.io/spec/facets/1-2-0/SchemaDatasetFacet.json#/$defs/SchemaDatasetFacet",
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
#>           "_schemaURL": "https://openlineage.io/spec/facets/1-2-0/SchemaDatasetFacet.json#/$defs/SchemaDatasetFacet",
#>           "fields": [
#>             {
#>               "name": "total"
#>             }
#>           ]
#>         },
#>         "columnLineage": {
#>           "_producer": "https://github.com/tgerke/dplyneage",
#>           "_schemaURL": "https://openlineage.io/spec/facets/1-2-0/ColumnLineageDatasetFacet.json#/$defs/ColumnLineageDatasetFacet",
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
#>   "schemaURL": "https://openlineage.io/spec/2-0-2/OpenLineage.json#/$defs/RunEvent"
#> } 
```
