# OpenLineage export and catalog round-trips

[OpenLineage](https://openlineage.io/) is the interchange format that
data catalogs and lineage backends ingest: Marquez, DataHub,
OpenMetadata, and a growing list of warehouses and orchestrators all
speak it. dplyneage emits it, which means lineage extracted from a dplyr
pipeline can sit in the same catalog as lineage from dbt, Airflow, or
Spark. No OpenLineage producer existed for R before this one.

This article covers what the events contain, the run-less static events
that fit design-time extraction, and a verified round-trip into a local
Marquez.

## A first event

[`lineage_openlineage()`](https://tgerke.github.io/dplyneage/reference/lineage_openlineage.md)
turns any extraction into an event document. The fixture here is a small
duckdb warehouse with an `orders` table:

``` r

library(dplyneage)
library(dplyr, warn.conflicts = FALSE)

con <- DBI::dbConnect(duckdb::duckdb())
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/RtmpavPAaQ/duckdb
#> This is removed when the R session ends.
#> • Extensions are re-downloaded each session.
#> • Secrets are lost.
#> ℹ Run duckdb(shared_home = TRUE) (or create ~/.duckdb) to keep them (suitable for most users).
#> ℹ Run duckdb(shared_home = FALSE) to accept the temporary directory (and silence this message).
#> ℹ See ?duckdb_storage for details and alternatives.
DBI::dbWriteTable(con, "orders", data.frame(
  order_id = 1:6,
  customer_id = rep(1:3, 2),
  amount = c(10, 20, 30, 40, 50, 60)
))

lineage <- tbl(con, "orders") |>
  group_by(customer_id) |>
  summarise(total = sum(amount, na.rm = TRUE)) |>
  extract_lineage(
    schema = list(orders = list(customer_id = "INTEGER", amount = "DOUBLE"))
  )

lineage_openlineage(
  lineage,
  run_id = "00000000-0000-4000-8000-000000000000",
  event_time = "2026-08-28T00:00:00.000Z",
  output_name = "daily_totals"
)
#> {
#>   "eventType": "COMPLETE",
#>   "eventTime": "2026-08-28T00:00:00.000Z",
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
#>       },
#>       "sql": {
#>         "_producer": "https://github.com/tgerke/dplyneage",
#>         "_schemaURL": "https://openlineage.io/spec/facets/1-1-0/SQLJobFacet.json#/$defs/SQLJobFacet",
#>         "query": "SELECT customer_id, SUM(amount) AS total\nFROM orders\nGROUP BY customer_id",
#>         "dialect": "duckdb"
#>       }
#>     }
#>   },
#>   "inputs": [
#>     {
#>       "namespace": "duckdb",
#>       "name": "orders",
#>       "facets": {
#>         "schema": {
#>           "_producer": "https://github.com/tgerke/dplyneage",
#>           "_schemaURL": "https://openlineage.io/spec/facets/1-2-0/SchemaDatasetFacet.json#/$defs/SchemaDatasetFacet",
#>           "fields": [
#>             {
#>               "name": "customer_id",
#>               "type": "INTEGER"
#>             },
#>             {
#>               "name": "amount",
#>               "type": "DOUBLE"
#>             }
#>           ]
#>         }
#>       }
#>     }
#>   ],
#>   "outputs": [
#>     {
#>       "namespace": "duckdb",
#>       "name": "daily_totals",
#>       "facets": {
#>         "schema": {
#>           "_producer": "https://github.com/tgerke/dplyneage",
#>           "_schemaURL": "https://openlineage.io/spec/facets/1-2-0/SchemaDatasetFacet.json#/$defs/SchemaDatasetFacet",
#>           "fields": [
#>             {
#>               "name": "customer_id",
#>               "type": "INTEGER"
#>             },
#>             {
#>               "name": "total"
#>             }
#>           ]
#>         },
#>         "columnLineage": {
#>           "_producer": "https://github.com/tgerke/dplyneage",
#>           "_schemaURL": "https://openlineage.io/spec/facets/1-2-0/ColumnLineageDatasetFacet.json#/$defs/ColumnLineageDatasetFacet",
#>           "fields": {
#>             "customer_id": {
#>               "inputFields": [
#>                 {
#>                   "namespace": "duckdb",
#>                   "name": "orders",
#>                   "field": "customer_id",
#>                   "transformations": [
#>                     {
#>                       "type": "DIRECT",
#>                       "subtype": "IDENTITY",
#>                       "description": "customer_id"
#>                     }
#>                   ]
#>                 }
#>               ]
#>             },
#>             "total": {
#>               "inputFields": [
#>                 {
#>                   "namespace": "duckdb",
#>                   "name": "orders",
#>                   "field": "amount",
#>                   "transformations": [
#>                     {
#>                       "type": "DIRECT",
#>                       "subtype": "AGGREGATION",
#>                       "description": "sum(amount, na.rm = TRUE)"
#>                     }
#>                   ]
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

A few things in that document are doing deliberate work.

**Namespaces come from the connection.** OpenLineage groups datasets by
namespace, and catalogs join incoming events to known datasets through
it, so the spec wants scheme URIs that identify the data store.
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
captures one from the table’s connection while it is alive:
`postgres://host:port` and `mysql://host:port` follow the spec’s
conventions, and file-backed duckdb or SQLite databases get
`duckdb:<path>` / `sqlite:<path>` (the bare scheme in memory, as here,
since the spec names no convention for either). Local frames via
[`dbplyr::tbl_lazy()`](https://dbplyr.tidyverse.org/reference/tbl_lazy.html)
have no data store, so their datasets keep the `dplyneage` default.
Passing `namespace =` overrides all of it. URI-shaped namespaces also
appear in each dataset’s `dataSource` facet.

**Schema facets carry types and descriptions when they are known.**
Types arrive two ways: on the sqlglot engine, extraction harvests names
and types from the connection with a zero-row probe per table; on any
engine, a `schema` argument with named entries (as above) supplies them
directly. The R engine skips the probe, so extractions that stay on it
report types only when you pass them. Field descriptions come from
column labels, which every engine collects: the `label` attributes haven
and labelled put on imported columns, column comments read from a live
connection’s catalog (duckdb and postgres; one small metadata query per
base table), or a `labels` argument like
`labels = list(orders = c(amount = "Order amount in USD"))`, which wins
over both. Whatever is captured also lands in
[`lineage_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md)
as per-node `types` and `labels` maps.

**Indirect lineage sits at the dataset level.** With
`extract_lineage(include_indirect = TRUE)`, filter, join, group and sort
columns shape every row of the result rather than any one output column.
The `columnLineage` facet has a slot for exactly that, the dataset-level
`dataset` array, and that is where they go. Per-column `inputFields`
stay reserved for direct lineage, so a consumer reading them sees real
column-to-column edges, not a filter fanned out to every output.

**The job knows what ran.** Single-model events carry a `sql` job facet
with the analyzed query and its dialect, plus a `jobType` facet (`BATCH`
/ `DPLYNEAGE` / `QUERY`). `event_type` sets the run state, and
`nominal_time` / `parent` attach the matching run facets when the
extraction runs under a scheduler.

## Static events: lineage without a run

dplyneage extracts lineage from code without executing it. OpenLineage
has a pair of event kinds for that situation, `JobEvent` and
`DatasetEvent`, which carry no `run` at all. Emitting them means a
design-time tool does not have to fabricate a run per extraction.

`events = "job"` produces one `JobEvent` per model. Each job is named
after its model, lists the datasets that model reads as inputs (upstream
models included), and carries its own `sql` facet:

``` r

silver <- tbl(con, "orders") |>
  group_by(customer_id) |>
  summarise(total_spent = sum(amount, na.rm = TRUE), .groups = "drop")

DBI::dbExecute(con, "
  CREATE TABLE silver_totals AS
  SELECT customer_id, SUM(amount) AS total_spent
  FROM orders GROUP BY customer_id
")
#> [1] 3
gold <- tbl(con, "silver_totals") |>
  mutate(big_spender = total_spent > 50)

pipeline <- extract_lineage(list(silver_totals = silver, gold = gold))

ndjson <- lineage_openlineage(
  pipeline,
  events = "job",
  event_time = "2026-08-28T00:00:00.000Z",
  pretty = FALSE
)
```

Several events serialize as NDJSON, one compact event per line. That is
the format OpenLineage’s `FileTransport` writes, so a committed events
file can be replayed into any backend later:

``` r

writeLines(substr(strsplit(ndjson, "\n")[[1]], 1, 76))
#> {"eventTime":"2026-08-28T00:00:00.000Z","job":{"namespace":"dplyneage","name
#> {"eventTime":"2026-08-28T00:00:00.000Z","job":{"namespace":"dplyneage","name
```

`events = "dataset"` emits one `DatasetEvent` per dataset instead, a
static schema registration with column lineage on the outputs. The kinds
combine: `events = c("job", "dataset")` produces both sets in one
document.

## Sending events with lineage_emit()

[`lineage_emit()`](https://tgerke.github.io/dplyneage/reference/lineage_emit.md)
builds the same events and POSTs each one to a backend, one request per
event, which is how the reference OpenLineage clients transport them:

``` r

lineage_emit(lineage, url = "http://localhost:5000")

# Design-time events, one job per model
lineage_emit(pipeline, url = "http://localhost:5000", events = "job")
```

The `url` and `api_key` arguments fall back to the `OPENLINEAGE_URL` and
`OPENLINEAGE_API_KEY` environment variables, the same ones the reference
clients read, so CI can configure the destination without touching code.
The default endpoint path `api/v1/lineage` is where Marquez listens;
DataHub exposes its OpenLineage endpoint under a prefix you can set with
`endpoint =`. A failed request stops with a `dplyneage_emit_failure`
condition carrying the HTTP status and the per-event results so far.

## A verified round-trip into Marquez

Everything below was run against a local
[Marquez](https://marquezproject.ai/), the OpenLineage reference
backend, in August 2026 (Marquez `latest`, spec 2-0-2 events). The
[quickstart](https://github.com/MarquezProject/marquez#quickstart)
brings one up with Docker; the API listens on port 5000. On macOS,
AirPlay occupies port 5000, so map another host port and pass that in
`url`.

The warehouse for the round-trip was a file-backed duckdb with the
`orders` / `silver_totals` / `gold` models from above, extracted with
`engine = "sqlglot"` so the schema facets carry harvested types.
Emitting one event per model is the pattern that lands full column
fidelity:

``` r

lineage_emit(
  extract_lineage(silver, engine = "sqlglot"),
  url = "http://localhost:15000",
  job_name = "silver_totals", output_name = "silver_totals"
)
lineage_emit(
  extract_lineage(gold, engine = "sqlglot"),
  url = "http://localhost:15000",
  job_name = "gold", output_name = "gold"
)
```

What Marquez then shows, queried straight from its API:

- Both namespaces registered: `dplyneage` for the jobs, and the captured
  `duckdb:<path to warehouse.duckdb>` for the datasets.
- The datasets with their schemas, types included:
  `orders (customer_id integer, amount numeric)`, and the `dataSource`
  facet carrying the duckdb URI.
- The job-level graph fully linked: `orders -> silver_totals -> gold`.
- Column-level lineage for every edge, cross-model edges included.
  Marquez’s `column_lineage` table after emission:

&nbsp;

     output_field | input_field | input_dataset
    --------------+-------------+---------------
     customer_id  | customer_id | orders
     total_spent  | amount      | orders
     big_spender  | total_spent | silver_totals
     customer_id  | customer_id | silver_totals
     total_spent  | total_spent | silver_totals

The static kinds round-trip too: Marquez accepts `JobEvent` and
`DatasetEvent` at the same endpoint, registers the jobs and datasets,
and stores their facets.

Two interop notes from the verification, before you wire this into a
real catalog:

- Marquez resolves an event’s column lineage against the datasets in
  that event’s `inputs`. In a whole-pipeline `RunEvent`, mid-pipeline
  models appear only in `outputs`, so the columns they feed downstream
  do not land in Marquez’s column lineage graph. Per-model emission, as
  above, avoids this entirely.
- Marquez’s node-addressed query endpoints parse ids on colons, and a
  `duckdb:/path` namespace contains one. The data ingests and displays
  fine, but if you plan to query Marquez’s `column-lineage` API
  directly, a colon-free `namespace =` override is the pragmatic choice.

## In CI

The [lineage checks in
CI](https://tgerke.github.io/dplyneage/articles/lineage-ci.html) article
gates pull requests on
[`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md).
Emission slots into the same job: after the gate passes on the default
branch, one more step sends the fresh lineage to your catalog.

``` yaml
- name: Publish lineage
  if: github.ref == 'refs/heads/main'
  env:
    OPENLINEAGE_URL: ${{ secrets.OPENLINEAGE_URL }}
    OPENLINEAGE_API_KEY: ${{ secrets.OPENLINEAGE_API_KEY }}
  run: Rscript -e 'lineage <- source("lineage/extract.R")$value
                   dplyneage::lineage_emit(lineage, events = "job")'
```

Committed NDJSON from `lineage_openlineage(events = "job")` is the
offline alternative: the artifact rides along in version control and
replays into a backend whenever one shows up.
