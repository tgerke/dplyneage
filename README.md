
<!-- README.md is generated from README.Rmd. Please edit that file -->

# dplyneage

<!-- badges: start -->

[![Lifecycle:
experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
[![R-CMD-check](https://github.com/tgerke/dplyneage/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/tgerke/dplyneage/actions/workflows/R-CMD-check.yaml)
<!-- badges: end -->

dplyneage draws interactive column-level lineage diagrams for dplyr and
dbplyr pipelines. Pipe a query into `extract_lineage()` and it traces
every output column back to the source columns it came from — through
joins, aggregations, CTEs, unions, and computed expressions — then
renders the result as a draggable, zoomable [React
Flow](https://reactflow.dev/) diagram with `lineage_flow()`.

dbplyr pipelines are analyzed in pure R by walking their lazy query
tree, so no Python is involved. Raw SQL goes through
[sqlglot](https://github.com/tobymao/sqlglot)’s dedicated lineage engine
instead, which means many dialects (DuckDB, PostgreSQL, Snowflake,
BigQuery, …) work too.

## Installation

``` r
pak::pak("tgerke/dplyneage")
```

dbplyr pipelines need no Python at all. For raw SQL input, the Python
dependency (sqlglot) is provisioned automatically the first time it’s
needed, via `reticulate::py_require()` — there is no setup step. See
`vignette("python-integration")` if you manage your own Python
environment.

## Usage

Build a dplyr pipeline against a database as usual, then pipe it into
`extract_lineage()` and `lineage_flow()`:

``` r
library(dplyneage)
library(dplyr)
library(dbplyr)
library(duckdb)

con <- dbConnect(duckdb::duckdb(), ":memory:")

customers <- tibble(
  customer_id = 1:5,
  first_name = c("Alice", "Bob", "Charlie", "Diana", "Eve"),
  last_name = c("Smith", "Jones", "Brown", "Wilson", "Davis"),
  email = paste0(tolower(first_name), "@example.com")
)

orders <- tibble(
  order_id = 1:10,
  customer_id = rep(1:5, each = 2),
  amount = c(100, 150, 200, 75, 300, 125, 180, 90, 250, 160)
)

copy_to(con, customers, "customers", overwrite = TRUE)
copy_to(con, orders, "orders", overwrite = TRUE)

tbl(con, "customers") |>
  select(customer_id, first_name, last_name, email) |>
  left_join(tbl(con, "orders"), by = "customer_id") |>
  group_by(customer_id, first_name, last_name, email) |>
  summarise(
    total_orders = n(),
    total_spent = sum(amount, na.rm = TRUE),
    .groups = "drop"
  ) |>
  extract_lineage() |>
  lineage_flow(height = "600px")
```

<img src="man/figures/README-unnamed-chunk-3-1.png" alt="Column-level lineage diagram with the customers and orders tables on the left and the summarised output table on the right, with edges tracing each output column back to its source columns"  />

Behind that one pipe, `extract_lineage()`:

- walks the pipeline’s lazy query tree in pure R, tracing every output
  column to its source columns (joins, aggregations, unions, and
  multi-source computed columns all resolve exactly)
- falls back to sqlglot’s lineage engine when the pipeline injects raw
  SQL with `dbplyr::sql()`, or when you pass a SQL string directly (that
  path handles aliases, CTEs, and subqueries, and reads table schemas
  from your connection so unqualified columns attribute correctly)

The resulting diagram is fully interactive: drag tables to rearrange,
zoom and pan, and hover columns to highlight their connections.

## Building diagrams by hand

For documentation or design work, you can construct lineage diagrams
directly with `create_table_node()` and `create_column_edge()`:

``` r
nodes <- list(
  create_table_node(
    table_name = "customers",
    columns = c("customer_id", "name", "email"),
    x = 0, y = 50,
    table_type = "source"
  ),
  create_table_node(
    table_name = "orders",
    columns = c("order_id", "customer_id", "total_amount"),
    x = 0, y = 300,
    table_type = "source"
  ),
  create_table_node(
    table_name = "customer_summary",
    columns = c("customer_id", "customer_name", "total_spent"),
    x = 500, y = 150,
    table_type = "target"
  )
)

edges <- list(
  create_column_edge("customers", "customer_id", "customer_summary", "customer_id"),
  create_column_edge("customers", "name", "customer_summary", "customer_name"),
  create_column_edge("orders", "total_amount", "customer_summary", "total_spent",
                     label = "SUM()", animated = TRUE)
)

lineage_flow(nodes, edges, height = "600px")
#> file:////private/var/folders/fw/0d9nr9951q57f0d5l6qc1j200000gn/T/RtmpvZgp4P/file8032ddf1b44/widget803127724e3.html screenshot completed
```

<img src="man/figures/README-unnamed-chunk-4-1.png" alt="Hand-built lineage diagram showing the customers and orders source tables in blue connected to a customer_summary target table in green, with a SUM() label on the total_spent edge"  />

Table types follow the color conventions used by dbt and SQLMesh:

| Type        | Color  | Use case                         |
|-------------|--------|----------------------------------|
| `source`    | Blue   | Raw/source tables                |
| `transform` | Orange | Intermediate transformations     |
| `target`    | Green  | Final output/materialized tables |

## Works with ducklake

Because `extract_lineage()` accepts any dbplyr lazy table, it composes
directly with packages that produce them — for example
[ducklake](https://github.com/tgerke/ducklake-r) tables:

``` r
library(ducklake)

get_ducklake_table("orders") |>
  dplyr::left_join(get_ducklake_table("customers"), by = "customer_id") |>
  dplyr::group_by(customer_id) |>
  dplyr::summarise(total = sum(amount, na.rm = TRUE)) |>
  extract_lineage() |>
  lineage_flow()
```

## Learn more

- `vignette("getting-started")` walks from a first diagram through CTEs,
  multi-source columns, and schemas
- `vignette("python-integration")` covers how the Python dependency is
  managed
- Full function reference at
  [tgerke.github.io/dplyneage](https://tgerke.github.io/dplyneage/)

## Roadmap

- ✅ Pure-R lineage fast path for dplyr-only pipelines (no Python), via
  dbplyr’s lazy query tree
- 🚧 Export lineage to common formats (JSON, GraphML)
