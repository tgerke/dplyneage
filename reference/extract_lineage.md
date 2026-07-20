# Extract column lineage from a dplyr pipeline or SQL query

`extract_lineage()` traces every output column of a query back to the
source table columns it was computed from. Pipe a dbplyr lazy table
straight into it, or pass a SQL string. Aliases, CTEs, subqueries, set
operations like `UNION`, and multi-source expressions such as
`COALESCE(a.x, b.x)` all resolve to their true source columns.

## Usage

``` r
extract_lineage(
  sql,
  dialect = "duckdb",
  schema = NULL,
  show_sql = FALSE,
  engine = c("auto", "sqlglot", "r"),
  include_indirect = FALSE
)
```

## Arguments

- sql:

  A dbplyr lazy table (`tbl_lazy`), a single SQL query string, or a
  named list of these (one element per pipeline model; see Details).
  Lazy tables are analyzed directly from their lazy query tree (the SQL
  recorded in `metadata` still comes from
  [`dbplyr::sql_render()`](https://dbplyr.tidyverse.org/reference/sql_build.html));
  when one is handled by the sqlglot engine instead, its database
  connection is used to harvest table schemas automatically. Plain data
  frames are not accepted — dplyr executes each verb on them
  immediately, leaving no query tree to read. Wrap the data with
  [`dbplyr::memdb_frame()`](https://dbplyr.tidyverse.org/reference/memdb.html)
  (or copy an existing frame with
  `copy_to(dbplyr::memdb(), df, name = "df")`) and the same pipeline
  becomes traceable; see
  [`vignette("getting-started")`](https://tgerke.github.io/dplyneage/articles/getting-started.md).

- dialect:

  SQL dialect the query is written in, e.g. `"duckdb"` (the default),
  `"postgres"`, `"mysql"`, `"snowflake"`, `"bigquery"`. Any dialect
  sqlglot understands works here.

- schema:

  Optional table schema used by the sqlglot engine to attribute
  unqualified columns to the right table and to expand `SELECT *`: a
  named list mapping table names to character vectors of column names,
  e.g. `list(orders = c("order_id", "amount"))`. Only relevant for SQL
  strings — the R engine reads exact provenance from the lazy query
  tree, and a lazy table that falls back to sqlglot harvests its schema
  from the database connection automatically.

- show_sql:

  If `TRUE`, print the SQL being analyzed. Useful for seeing what dbplyr
  generated from your pipeline. Default: `FALSE`.

- engine:

  Which lineage engine to use. `"auto"` (the default) uses the pure-R
  engine for lazy tables when dbplyr (\>= 2.5.0) is installed, falling
  back to sqlglot for SQL strings or unsupported constructs. `"r"`
  forces the pure-R engine and errors on anything it cannot trace.
  `"sqlglot"` always renders to SQL and analyzes with sqlglot.

- include_indirect:

  If `TRUE`, columns used in
  [`filter()`](https://dplyr.tidyverse.org/reference/filter.html)/`WHERE`,
  join conditions,
  [`group_by()`](https://dplyr.tidyverse.org/reference/group_by.html),
  and
  [`arrange()`](https://dplyr.tidyverse.org/reference/arrange.html)/`ORDER BY`
  also appear in the diagram, connected by dashed edges (see Details).
  Default: `FALSE`, matching most lineage tools.

## Value

A list with `nodes` and `edges` ready to pass to
[`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md),
plus `metadata` recording the analyzed SQL, the dialect, the engine
used, and node/edge counts.

## Details

Two engines are available. dbplyr lazy tables are analyzed by a pure-R
fast path that walks the pipeline's lazy query tree directly — no Python
required. SQL strings are analyzed by
[sqlglot](https://github.com/tobymao/sqlglot)'s lineage engine via
reticulate (a Suggests dependency: install reticulate to enable this
engine; sqlglot itself is provisioned automatically). If a pipeline uses
a construct the R engine cannot trace (e.g. raw SQL injected with
[`dbplyr::sql()`](https://dbplyr.tidyverse.org/reference/sql.html)), it
falls back to sqlglot automatically.

Both engines trace select-list lineage by default: columns used only in
[`filter()`](https://dplyr.tidyverse.org/reference/filter.html), join
conditions, or
[`arrange()`](https://dplyr.tidyverse.org/reference/arrange.html) do not
create lineage edges. Set `include_indirect = TRUE` to add them as
dashed edges — a column that only filters the result still breaks the
pipeline if it is dropped, so impact analysis usually wants them.
Indirect edges connect each filter/join/group/sort column to every
output column, since these conditions shape the whole result, and are
classified by how the column is used (`"filter"`, `"join"`,
`"group_by"`, `"sort"`).

A named list stitches a multi-model pipeline into one graph. Each
element (lazy table or SQL string) is analyzed on its own, and any
source table whose name matches another element's name connects to that
model's node — so a bronze/silver/gold flow where each layer is
materialized under its model's name renders as a single multi-hop DAG,
with intermediate models drawn as orange transform nodes and terminal
models as green targets.

## See also

[`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md)
to render the result;
[`vignette("getting-started")`](https://tgerke.github.io/dplyneage/articles/getting-started.md)
for a tour from simple pipelines to CTEs and multi-source columns.

## Examples

``` r
# Raw SQL: qualified columns resolve on their own
extract_lineage("SELECT c.id, c.name FROM customers c") |>
  lineage_flow()

{"x":{"nodes":[{"id":"customers","type":"tableNode","data":{"label":"customers","columns":["id","name"],"tableType":"source","colors":{"bg":"#f0f7ff","border":"#3b82f6","header":"#1d4ed8"}},"position":{"x":0,"y":0},"draggable":true,"sourcePosition":"right","targetPosition":"left"},{"id":"output","type":"tableNode","data":{"label":"output","columns":["id","name"],"tableType":"target","colors":{"bg":"#f0fdf4","border":"#10b981","header":"#059669"}},"position":{"x":400,"y":0},"draggable":true,"sourcePosition":"right","targetPosition":"left"}],"edges":[{"id":"e_customers.id_to_output.id","source":"customers","target":"output","sourceHandle":"id","targetHandle":"id","animated":false,"style":{"stroke":"#64748b","strokeWidth":2},"data":{"expression":"c.id","transformation":"identity"}},{"id":"e_customers.name_to_output.name","source":"customers","target":"output","sourceHandle":"name","targetHandle":"name","animated":false,"style":{"stroke":"#64748b","strokeWidth":2},"data":{"expression":"c.name","transformation":"identity"}}]},"evals":[],"jsHooks":[]}
# Supply a schema so unqualified columns attribute to the right table
# and SELECT * expands
extract_lineage(
  "SELECT c.name, order_date FROM customers c
   JOIN orders o ON c.id = o.customer_id",
  schema = list(
    customers = c("id", "name"),
    orders = c("customer_id", "order_date")
  )
)
#> <dplyneage lineage>
#>   engine: sqlglot (dialect: duckdb)
#>   sources: customers, orders
#>   output: name, order_date
#>   2 column edges
# dbplyr pipelines: pipe straight in; the pure-R engine reads exact
# provenance from the pipeline itself, no Python needed
library(dplyr)
#> 
#> Attaching package: ‘dplyr’
#> The following objects are masked from ‘package:stats’:
#> 
#>     filter, lag
#> The following objects are masked from ‘package:base’:
#> 
#>     intersect, setdiff, setequal, union

con <- DBI::dbConnect(duckdb::duckdb())
#> duckdb is keeping downloaded extensions in a temporary directory:
#> ℹ /tmp/Rtmpv2DgMr/duckdb/extensions
#> This is removed when the R session ends, so extensions are re-downloaded each session.
#> ℹ To keep them, point `options(duckdb.extension_directory =)` or the `DUCKDB_EXTENSION_DIRECTORY` environment variable at a permanent path.
DBI::dbWriteTable(con, "customers", data.frame(id = 1, name = "a"))
DBI::dbWriteTable(con, "orders", data.frame(customer_id = 1, amount = 10))

tbl(con, "customers") |>
  left_join(tbl(con, "orders"), by = c("id" = "customer_id")) |>
  group_by(id, name) |>
  summarise(total_spent = sum(amount, na.rm = TRUE), .groups = "drop") |>
  extract_lineage() |>
  lineage_flow()

{"x":{"nodes":[{"id":"customers","type":"tableNode","data":{"label":"customers","columns":["id","name"],"tableType":"source","colors":{"bg":"#f0f7ff","border":"#3b82f6","header":"#1d4ed8"}},"position":{"x":0,"y":0},"draggable":true,"sourcePosition":"right","targetPosition":"left"},{"id":"orders","type":"tableNode","data":{"label":"orders","columns":"amount","tableType":"source","colors":{"bg":"#f0f7ff","border":"#3b82f6","header":"#1d4ed8"}},"position":{"x":0,"y":170},"draggable":true,"sourcePosition":"right","targetPosition":"left"},{"id":"output","type":"tableNode","data":{"label":"output","columns":["id","name","total_spent"],"tableType":"target","colors":{"bg":"#f0fdf4","border":"#10b981","header":"#059669"}},"position":{"x":400,"y":52},"draggable":true,"sourcePosition":"right","targetPosition":"left"}],"edges":[{"id":"e_customers.id_to_output.id","source":"customers","target":"output","sourceHandle":"id","targetHandle":"id","animated":false,"style":{"stroke":"#64748b","strokeWidth":2},"data":{"expression":"id","transformation":"identity"}},{"id":"e_customers.name_to_output.name","source":"customers","target":"output","sourceHandle":"name","targetHandle":"name","animated":false,"style":{"stroke":"#64748b","strokeWidth":2},"data":{"expression":"name","transformation":"identity"}},{"id":"e_orders.amount_to_output.total_spent","source":"orders","target":"output","sourceHandle":"amount","targetHandle":"total_spent","animated":true,"style":{"stroke":"#64748b","strokeWidth":2},"label":"sum(amount, na.rm = TRUE)","labelStyle":{"fill":"#64748b","fontWeight":500,"fontSize":11},"labelBgStyle":{"fill":"#ffffff","fillOpacity":0.9},"data":{"expression":"sum(amount, na.rm = TRUE)","transformation":"aggregation"}}]},"evals":[],"jsHooks":[]}
# Multi-model pipelines: name each step and pass a named list; source
# tables matching a model name stitch the layers into one DAG
silver <- tbl(con, "orders") |>
  group_by(customer_id) |>
  summarise(total_spent = sum(amount, na.rm = TRUE), .groups = "drop")
invisible(compute(silver, name = "silver", temporary = TRUE))
gold <- tbl(con, "silver") |>
  mutate(big_spender = total_spent > 100)

extract_lineage(list(silver = silver, gold = gold)) |>
  lineage_flow()

{"x":{"nodes":[{"id":"orders","type":"tableNode","data":{"label":"orders","columns":["customer_id","amount"],"tableType":"source","colors":{"bg":"#f0f7ff","border":"#3b82f6","header":"#1d4ed8"}},"position":{"x":0,"y":16.5},"draggable":true,"sourcePosition":"right","targetPosition":"left"},{"id":"silver","type":"tableNode","data":{"label":"silver","columns":["customer_id","total_spent"],"tableType":"transform","colors":{"bg":"#fef3f2","border":"#f59e0b","header":"#d97706"}},"position":{"x":400,"y":16.5},"draggable":true,"sourcePosition":"right","targetPosition":"left"},{"id":"gold","type":"tableNode","data":{"label":"gold","columns":["customer_id","total_spent","big_spender"],"tableType":"target","colors":{"bg":"#f0fdf4","border":"#10b981","header":"#059669"}},"position":{"x":800,"y":0},"draggable":true,"sourcePosition":"right","targetPosition":"left"}],"edges":[{"id":"e_orders.customer_id_to_silver.customer_id","source":"orders","target":"silver","sourceHandle":"customer_id","targetHandle":"customer_id","animated":false,"style":{"stroke":"#64748b","strokeWidth":2},"data":{"expression":"customer_id","transformation":"identity"}},{"id":"e_orders.amount_to_silver.total_spent","source":"orders","target":"silver","sourceHandle":"amount","targetHandle":"total_spent","animated":true,"style":{"stroke":"#64748b","strokeWidth":2},"label":"sum(amount, na.rm = TRUE)","labelStyle":{"fill":"#64748b","fontWeight":500,"fontSize":11},"labelBgStyle":{"fill":"#ffffff","fillOpacity":0.9},"data":{"expression":"sum(amount, na.rm = TRUE)","transformation":"aggregation"}},{"id":"e_silver.customer_id_to_gold.customer_id","source":"silver","target":"gold","sourceHandle":"customer_id","targetHandle":"customer_id","animated":false,"style":{"stroke":"#64748b","strokeWidth":2},"data":{"expression":"customer_id","transformation":"identity"}},{"id":"e_silver.total_spent_to_gold.total_spent","source":"silver","target":"gold","sourceHandle":"total_spent","targetHandle":"total_spent","animated":false,"style":{"stroke":"#64748b","strokeWidth":2},"data":{"expression":"total_spent","transformation":"identity"}},{"id":"e_silver.total_spent_to_gold.big_spender","source":"silver","target":"gold","sourceHandle":"total_spent","targetHandle":"big_spender","animated":false,"style":{"stroke":"#64748b","strokeWidth":2},"label":"total_spent > 100","labelStyle":{"fill":"#64748b","fontWeight":500,"fontSize":11},"labelBgStyle":{"fill":"#ffffff","fillOpacity":0.9},"data":{"expression":"total_spent > 100","transformation":"transformation"}}]},"evals":[],"jsHooks":[]}
DBI::dbDisconnect(con)
```
