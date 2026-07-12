# dplyneage

dplyneage draws interactive column-level lineage diagrams for dplyr and
dbplyr pipelines. Pipe a query into
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
and it traces every output column back to the source columns it came
from — through joins, aggregations, CTEs, unions, and computed
expressions — then renders the result as a draggable, zoomable [React
Flow](https://reactflow.dev/) diagram with
[`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md).

dbplyr pipelines are analyzed in pure R by walking their lazy query
tree, so no Python is involved. Raw SQL goes through
[sqlglot](https://github.com/tobymao/sqlglot)’s dedicated lineage engine
instead, which means many dialects (DuckDB, PostgreSQL, Snowflake,
BigQuery, …) work too.

## Installation

``` r

pak::pak("tgerke/dplyneage")
```

dbplyr pipelines need no Python at all — not even reticulate. For raw
SQL input, install the reticulate package once; the Python dependency
(sqlglot) is then provisioned automatically the first time it’s needed.
See
[`vignette("python-integration")`](https://tgerke.github.io/dplyneage/articles/python-integration.md)
if you manage your own Python environment.

## Usage

Build a dplyr pipeline against a database as usual, then pipe it into
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
and
[`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md):

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
    total_orders = n_distinct(order_id),
    total_spent = sum(amount, na.rm = TRUE),
    .groups = "drop"
  ) |>
  extract_lineage() |>
  lineage_flow(height = "600px")
```

![Column-level lineage diagram with the customers and orders tables on
the left and the summarised output table on the right, with edges
tracing each output column back to its source
columns](reference/figures/README-unnamed-chunk-3-1.png)

Behind that one pipe,
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md):

- walks the pipeline’s lazy query tree in pure R, tracing every output
  column to its source columns (joins, aggregations, unions, and
  multi-source computed columns all resolve exactly)
- falls back to sqlglot’s lineage engine when the pipeline injects raw
  SQL with
  [`dbplyr::sql()`](https://dbplyr.tidyverse.org/reference/sql.html), or
  when you pass a SQL string directly (that path handles aliases, CTEs,
  and subqueries, and reads table schemas from your connection so
  unqualified columns attribute correctly)

The resulting diagram is fully interactive: drag tables to rearrange,
zoom and pan, and hover columns to highlight their connections. Computed
columns carry their defining expression as an edge label, and
aggregation edges animate.

## Local data frames

Lineage extraction needs the lazy query tree that dbplyr builds before
anything executes. A pipeline on a plain tibble has no such tree — dplyr
runs each verb immediately — so
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
can’t trace it. The workaround is one line:
[`dbplyr::memdb_frame()`](https://dbplyr.tidyverse.org/reference/memdb.html)
puts the data in a throwaway in-memory SQLite database and hands back a
lazy table, and the identical pipeline becomes traceable.

``` r

sales <- memdb_frame(
  customer_id = c(1, 1, 2),
  amount = c(100, 250, 40),
  .name = "sales"
)

sales |>
  group_by(customer_id) |>
  summarise(total = sum(amount, na.rm = TRUE)) |>
  extract_lineage() |>
  lineage_flow(height = "350px")
```

![Column-level lineage diagram tracing the summarised output table's
total column back to the amount column of the sales source
table](reference/figures/README-unnamed-chunk-4-1.png)

For a data frame you already have,
`copy_to(dbplyr::memdb(), df, name = "df")` does the same copy. Lineage
depends only on the pipeline’s structure, never on the data, so for
large frames copying a slice is enough —
`copy_to(dbplyr::memdb(), head(df), name = "df")` yields the same
diagram as copying every row. See the [Local data
frames](https://tgerke.github.io/dplyneage/articles/getting-started.html#local-data-frames)
section of the getting-started vignette for more.

## Multi-model pipelines

Real pipelines materialize layers — bronze tables feed a silver summary,
silver feeds gold. Pass
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
a named list, one element per layer, and it stitches them into a single
DAG: any source table whose name matches another element’s name links to
that model’s node.

``` r

silver <- tbl(con, "orders") |>
  group_by(customer_id) |>
  summarise(total_spent = sum(amount, na.rm = TRUE), .groups = "drop")
invisible(compute(silver, name = "silver", temporary = TRUE))

gold <- tbl(con, "silver") |>
  mutate(big_spender = total_spent > 400)

extract_lineage(list(silver = silver, gold = gold)) |>
  lineage_flow(height = "450px")
```

![Three-layer lineage diagram: the orders source table in blue feeds the
silver transform table in orange, which feeds the gold target table in
green, with column-level edges through all three
layers](reference/figures/README-unnamed-chunk-5-1.png)

Intermediate models render as orange transform nodes, terminal models as
green targets, and impact questions now span the whole pipeline:

``` r

extract_lineage(list(silver = silver, gold = gold)) |>
  lineage_upstream("gold.big_spender")
#> [1] "orders.amount"      "silver.total_spent"
```

## Building diagrams by hand

For documentation or design work, you can construct lineage diagrams
directly with
[`create_table_node()`](https://tgerke.github.io/dplyneage/reference/create_table_node.md)
and
[`create_column_edge()`](https://tgerke.github.io/dplyneage/reference/create_column_edge.md):

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
```

![Hand-built lineage diagram showing the customers and orders source
tables in blue connected to a customer_summary target table in green,
with a SUM() label on the total_spent
edge](reference/figures/README-unnamed-chunk-7-1.png)

Table types follow the color conventions used by dbt and SQLMesh:

| Type        | Color  | Use case                         |
|-------------|--------|----------------------------------|
| `source`    | Blue   | Raw/source tables                |
| `transform` | Orange | Intermediate transformations     |
| `target`    | Green  | Final output/materialized tables |

## Works with ducklake

Because
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
accepts any dbplyr lazy table, it composes directly with packages that
produce them — for example
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

The [ducklake lineage
vignette](https://tgerke.github.io/dplyneage/articles/ducklake-lineage.html)
works through a full example: building a small lake, diagramming each
layer of a bronze/silver/gold pipeline, and extracting lineage from
time-travel queries.

## Lineage as data

Diagrams are for people; the same lineage is also useful as plain data.
[`lineage_edges()`](https://tgerke.github.io/dplyneage/reference/lineage_edges.md)
flattens it to one classified row per column edge, and
[`lineage_upstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)
/
[`lineage_downstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)
answer impact questions directly:

``` r

lineage <- tbl(con, "orders") |>
  left_join(tbl(con, "customers"), by = "customer_id") |>
  group_by(customer_id, first_name) |>
  summarise(total_spent = sum(amount, na.rm = TRUE), .groups = "drop") |>
  extract_lineage()

lineage_edges(lineage)
#>   source_table source_column target_table target_column transformation
#> 1       orders   customer_id       output   customer_id       identity
#> 2    customers    first_name       output    first_name       identity
#> 3       orders        amount       output   total_spent    aggregation
#>                  expression
#> 1               customer_id
#> 2                first_name
#> 3 sum(amount, na.rm = TRUE)

lineage_upstream(lineage, "output.total_spent")
#> [1] "orders.amount"
```

[`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md)
compares two extractions — run it across branches in CI and provenance
changes surface before they ship. For interchange,
[`lineage_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md)
gives you a small, stable document you can query with jq, feed to a data
catalog, or commit next to your pipeline code:

``` r

lineage_json(lineage)
#> {
#>   "metadata": {
#>     "sql": "SELECT customer_id, first_name, SUM(amount) AS total_spent\nFROM (\n  SELECT orders.*, first_name, last_name, email\n  FROM orders\n  LEFT JOIN customers\n    ON (orders.customer_id = customers.customer_id)\n) AS q01\nGROUP BY customer_id, first_name",
#>     "dialect": "duckdb",
#>     "engine": "r",
#>     "node_count": 3,
#>     "edge_count": 3
#>   },
#>   "nodes": [
#>     {
#>       "id": "orders",
#>       "type": "source",
#>       "columns": ["customer_id", "amount"]
#>     },
#>     {
#>       "id": "customers",
#>       "type": "source",
#>       "columns": ["first_name"]
#>     },
#>     {
#>       "id": "output",
#>       "type": "target",
#>       "columns": ["customer_id", "first_name", "total_spent"]
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
#>       "source": "customers",
#>       "source_column": "first_name",
#>       "target": "output",
#>       "target_column": "first_name",
#>       "transformation": "identity",
#>       "expression": "first_name"
#>     },
#>     {
#>       "source": "orders",
#>       "source_column": "amount",
#>       "target": "output",
#>       "target_column": "total_spent",
#>       "transformation": "aggregation",
#>       "expression": "sum(amount, na.rm = TRUE)"
#>     }
#>   ]
#> }
```

Written to a file, that document is scriptable from outside R entirely —
here’s jq answering “which source columns feed `total_spent`?”:

``` r

lineage_json(lineage, "lineage.json")
```

``` bash
jq -r '.edges[] | select(.target_column == "total_spent")
       | "\(.source).\(.source_column)"' lineage.json
#> orders.amount
```

[`lineage_graphml()`](https://tgerke.github.io/dplyneage/reference/lineage_graphml.md)
writes GraphML, which opens directly in graph tools like Gephi, yEd, and
igraph. The same question works as a graph query — and scales to
transitive ancestry when pipelines chain:

``` r

path <- tempfile(fileext = ".graphml")
lineage_graphml(lineage, path)

g <- igraph::read_graph(path, format = "graphml")
igraph::subcomponent(g, "output.total_spent", mode = "in")
#> + 2/6 vertices, named, from fb656f2:
#> [1] output.total_spent orders.amount
```

## Learn more

- [`vignette("getting-started")`](https://tgerke.github.io/dplyneage/articles/getting-started.md)
  walks from a first diagram through CTEs, multi-source columns, and
  schemas
- [`vignette("python-integration")`](https://tgerke.github.io/dplyneage/articles/python-integration.md)
  covers how the Python dependency is managed
- Full function reference at
  [tgerke.github.io/dplyneage](https://tgerke.github.io/dplyneage/)
