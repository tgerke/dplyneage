# Send OpenLineage events to a backend over HTTP

Builds the same events as
[`lineage_openlineage()`](https://tgerke.github.io/dplyneage/reference/lineage_openlineage.md)
and POSTs each one to an OpenLineage endpoint, so dplyneage-extracted
lineage lands in a running catalog — Marquez, DataHub, or anything else
that speaks the protocol — next to lineage from dbt, Airflow, or Spark.
One request per event, JSON body, matching how the reference OpenLineage
clients transport events.

## Usage

``` r
lineage_emit(
  lineage,
  url = NULL,
  events = "run",
  namespace = NULL,
  job_name = "extract_lineage",
  run_id = NULL,
  event_time = NULL,
  event_type = "COMPLETE",
  output_name = NULL,
  nominal_time = NULL,
  parent = NULL,
  api_key = NULL,
  headers = NULL,
  endpoint = "api/v1/lineage"
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

- url:

  Base URL of the OpenLineage backend, e.g. `"http://localhost:5000"`
  for a local Marquez. Defaults to the `OPENLINEAGE_URL` environment
  variable, the same one the reference clients read.

- events:

  Which event kinds to emit: any combination of `"run"` (the default;
  one `RunEvent` for the whole extraction), `"job"` (run-less
  `JobEvent`s, one per model), and `"dataset"` (run-less
  `DatasetEvent`s, one per dataset). See the Static lineage events
  section.

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

- api_key:

  Bearer token added as an `Authorization` header. Defaults to the
  `OPENLINEAGE_API_KEY` environment variable; unset means no auth
  header.

- headers:

  A named character vector or list of extra HTTP headers.

- endpoint:

  Path of the lineage endpoint under `url`.

## Value

Invisibly, a data frame with one row per event sent: `event` (index) and
`status` (HTTP status code).

## Details

The default endpoint path `api/v1/lineage` is where Marquez listens; for
other backends set `endpoint` (DataHub, for example, exposes the
OpenLineage endpoint under its own prefix). Marquez accepts run events
and the static `events = "job"` / `events = "dataset"` kinds alike.

## Errors

A failed request — connection refused, or an HTTP error status — stops
with a condition of class `dplyneage_emit_failure` carrying `event` (the
failing index), `status` (the HTTP status, `NA` when the request never
got a response), and `results` (the rows for events already sent).
Events after the failing one are not sent.

## See also

[`lineage_openlineage()`](https://tgerke.github.io/dplyneage/reference/lineage_openlineage.md)
for the event documents themselves

Other lineage exporters:
[`lineage_graphml()`](https://tgerke.github.io/dplyneage/reference/lineage_graphml.md),
[`lineage_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md),
[`lineage_mermaid()`](https://tgerke.github.io/dplyneage/reference/lineage_mermaid.md),
[`lineage_openlineage()`](https://tgerke.github.io/dplyneage/reference/lineage_openlineage.md)

## Examples

``` r
if (FALSE) { # \dontrun{
lineage <- extract_lineage(my_query)

# A local Marquez quickstart listens on port 5000
lineage_emit(lineage, url = "http://localhost:5000")

# Design-time lineage, no fabricated run, nested under a known job
lineage_emit(lineage, url = "http://localhost:5000", events = "job")
} # }
```
