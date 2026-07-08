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
  engine = c("auto", "sqlglot", "r")
)
```

## Arguments

- sql:

  A dbplyr lazy table (`tbl_lazy`) or a single SQL query string. Lazy
  tables are analyzed directly from their lazy query tree (the SQL
  recorded in `metadata` still comes from
  [`dbplyr::sql_render()`](https://dbplyr.tidyverse.org/reference/sql_build.html));
  when one is handled by the sqlglot engine instead, its database
  connection is used to harvest table schemas automatically.

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
reticulate. If a pipeline uses a construct the R engine cannot trace
(e.g. raw SQL injected with
[`dbplyr::sql()`](https://dbplyr.tidyverse.org/reference/sql.html)), it
falls back to sqlglot automatically.

Both engines trace select-list lineage: columns used only in
[`filter()`](https://dplyr.tidyverse.org/reference/filter.html), join
conditions, or
[`arrange()`](https://dplyr.tidyverse.org/reference/arrange.html) do not
create lineage edges.

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

{"x":{"nodes":[{"id":"customers","type":"tableNode","data":{"label":"customers","columns":["id","name"],"tableType":"source","colors":{"bg":"#f0f7ff","border":"#3b82f6","header":"#1d4ed8"}},"position":{"x":0,"y":0},"draggable":true,"sourcePosition":"right","targetPosition":"left"},{"id":"output","type":"tableNode","data":{"label":"output","columns":["id","name"],"tableType":"target","colors":{"bg":"#f0fdf4","border":"#10b981","header":"#059669"}},"position":{"x":400,"y":0},"draggable":true,"sourcePosition":"right","targetPosition":"left"}],"edges":[{"id":"e_customers.id_to_output.id","source":"customers","target":"output","sourceHandle":"id","targetHandle":"id","animated":false,"style":{"stroke":"#64748b","strokeWidth":2}},{"id":"e_customers.name_to_output.name","source":"customers","target":"output","sourceHandle":"name","targetHandle":"name","animated":false,"style":{"stroke":"#64748b","strokeWidth":2}}]},"evals":[],"jsHooks":[]}
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
#> $nodes
#> $nodes[[1]]
#> $nodes[[1]]$id
#> [1] "customers"
#> 
#> $nodes[[1]]$type
#> [1] "tableNode"
#> 
#> $nodes[[1]]$data
#> $nodes[[1]]$data$label
#> [1] "customers"
#> 
#> $nodes[[1]]$data$columns
#> [1] "name"
#> 
#> $nodes[[1]]$data$tableType
#> [1] "source"
#> 
#> $nodes[[1]]$data$colors
#> $nodes[[1]]$data$colors$bg
#> [1] "#f0f7ff"
#> 
#> $nodes[[1]]$data$colors$border
#> [1] "#3b82f6"
#> 
#> $nodes[[1]]$data$colors$header
#> [1] "#1d4ed8"
#> 
#> 
#> 
#> $nodes[[1]]$position
#> $nodes[[1]]$position$x
#> [1] 0
#> 
#> $nodes[[1]]$position$y
#> [1] 0
#> 
#> 
#> $nodes[[1]]$draggable
#> [1] TRUE
#> 
#> $nodes[[1]]$sourcePosition
#> [1] "right"
#> 
#> $nodes[[1]]$targetPosition
#> [1] "left"
#> 
#> 
#> $nodes[[2]]
#> $nodes[[2]]$id
#> [1] "orders"
#> 
#> $nodes[[2]]$type
#> [1] "tableNode"
#> 
#> $nodes[[2]]$data
#> $nodes[[2]]$data$label
#> [1] "orders"
#> 
#> $nodes[[2]]$data$columns
#> [1] "order_date"
#> 
#> $nodes[[2]]$data$tableType
#> [1] "source"
#> 
#> $nodes[[2]]$data$colors
#> $nodes[[2]]$data$colors$bg
#> [1] "#f0f7ff"
#> 
#> $nodes[[2]]$data$colors$border
#> [1] "#3b82f6"
#> 
#> $nodes[[2]]$data$colors$header
#> [1] "#1d4ed8"
#> 
#> 
#> 
#> $nodes[[2]]$position
#> $nodes[[2]]$position$x
#> [1] 0
#> 
#> $nodes[[2]]$position$y
#> [1] 200
#> 
#> 
#> $nodes[[2]]$draggable
#> [1] TRUE
#> 
#> $nodes[[2]]$sourcePosition
#> [1] "right"
#> 
#> $nodes[[2]]$targetPosition
#> [1] "left"
#> 
#> 
#> $nodes[[3]]
#> $nodes[[3]]$id
#> [1] "output"
#> 
#> $nodes[[3]]$type
#> [1] "tableNode"
#> 
#> $nodes[[3]]$data
#> $nodes[[3]]$data$label
#> [1] "output"
#> 
#> $nodes[[3]]$data$columns
#> [1] "name"       "order_date"
#> 
#> $nodes[[3]]$data$tableType
#> [1] "target"
#> 
#> $nodes[[3]]$data$colors
#> $nodes[[3]]$data$colors$bg
#> [1] "#f0fdf4"
#> 
#> $nodes[[3]]$data$colors$border
#> [1] "#10b981"
#> 
#> $nodes[[3]]$data$colors$header
#> [1] "#059669"
#> 
#> 
#> 
#> $nodes[[3]]$position
#> $nodes[[3]]$position$x
#> [1] 400
#> 
#> $nodes[[3]]$position$y
#> [1] 100
#> 
#> 
#> $nodes[[3]]$draggable
#> [1] TRUE
#> 
#> $nodes[[3]]$sourcePosition
#> [1] "right"
#> 
#> $nodes[[3]]$targetPosition
#> [1] "left"
#> 
#> 
#> 
#> $edges
#> $edges[[1]]
#> $edges[[1]]$id
#> [1] "e_customers.name_to_output.name"
#> 
#> $edges[[1]]$source
#> [1] "customers"
#> 
#> $edges[[1]]$target
#> [1] "output"
#> 
#> $edges[[1]]$sourceHandle
#> [1] "name"
#> 
#> $edges[[1]]$targetHandle
#> [1] "name"
#> 
#> $edges[[1]]$animated
#> [1] FALSE
#> 
#> $edges[[1]]$style
#> $edges[[1]]$style$stroke
#> [1] "#64748b"
#> 
#> $edges[[1]]$style$strokeWidth
#> [1] 2
#> 
#> 
#> 
#> $edges[[2]]
#> $edges[[2]]$id
#> [1] "e_orders.order_date_to_output.order_date"
#> 
#> $edges[[2]]$source
#> [1] "orders"
#> 
#> $edges[[2]]$target
#> [1] "output"
#> 
#> $edges[[2]]$sourceHandle
#> [1] "order_date"
#> 
#> $edges[[2]]$targetHandle
#> [1] "order_date"
#> 
#> $edges[[2]]$animated
#> [1] FALSE
#> 
#> $edges[[2]]$style
#> $edges[[2]]$style$stroke
#> [1] "#64748b"
#> 
#> $edges[[2]]$style$strokeWidth
#> [1] 2
#> 
#> 
#> 
#> 
#> $metadata
#> $metadata$sql
#> [1] "SELECT c.name, order_date FROM customers c\n   JOIN orders o ON c.id = o.customer_id"
#> 
#> $metadata$dialect
#> [1] "duckdb"
#> 
#> $metadata$engine
#> [1] "sqlglot"
#> 
#> $metadata$table_count
#> [1] 3
#> 
#> $metadata$edge_count
#> [1] 2
#> 
#> 
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
DBI::dbWriteTable(con, "customers", data.frame(id = 1, name = "a"))
DBI::dbWriteTable(con, "orders", data.frame(customer_id = 1, amount = 10))

tbl(con, "customers") |>
  left_join(tbl(con, "orders"), by = c("id" = "customer_id")) |>
  group_by(id, name) |>
  summarise(total_spent = sum(amount, na.rm = TRUE), .groups = "drop") |>
  extract_lineage() |>
  lineage_flow()

{"x":{"nodes":[{"id":"customers","type":"tableNode","data":{"label":"customers","columns":["id","name"],"tableType":"source","colors":{"bg":"#f0f7ff","border":"#3b82f6","header":"#1d4ed8"}},"position":{"x":0,"y":0},"draggable":true,"sourcePosition":"right","targetPosition":"left"},{"id":"orders","type":"tableNode","data":{"label":"orders","columns":"amount","tableType":"source","colors":{"bg":"#f0f7ff","border":"#3b82f6","header":"#1d4ed8"}},"position":{"x":0,"y":200},"draggable":true,"sourcePosition":"right","targetPosition":"left"},{"id":"output","type":"tableNode","data":{"label":"output","columns":["id","name","total_spent"],"tableType":"target","colors":{"bg":"#f0fdf4","border":"#10b981","header":"#059669"}},"position":{"x":400,"y":100},"draggable":true,"sourcePosition":"right","targetPosition":"left"}],"edges":[{"id":"e_customers.id_to_output.id","source":"customers","target":"output","sourceHandle":"id","targetHandle":"id","animated":false,"style":{"stroke":"#64748b","strokeWidth":2}},{"id":"e_customers.name_to_output.name","source":"customers","target":"output","sourceHandle":"name","targetHandle":"name","animated":false,"style":{"stroke":"#64748b","strokeWidth":2}},{"id":"e_orders.amount_to_output.total_spent","source":"orders","target":"output","sourceHandle":"amount","targetHandle":"total_spent","animated":false,"style":{"stroke":"#64748b","strokeWidth":2}}]},"evals":[],"jsHooks":[]}
DBI::dbDisconnect(con)
```
