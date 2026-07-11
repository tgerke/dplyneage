# Getting Started with dplyneage

dplyneage answers a simple question about your data pipelines: *where
did each column come from?* You pipe a dplyr/dbplyr query (or pass raw
SQL) into
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md),
and render the answer as an interactive diagram with
[`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md).

This vignette starts with the smallest possible example and works up to
the cases where lineage gets genuinely hard: joins with ambiguous
columns, CTEs, and columns computed from several sources at once.

## Installation

``` r

pak::pak("tgerke/dplyneage")
```

dplyr/dbplyr pipelines are analyzed entirely in R, so for those there is
nothing else to install. Raw SQL strings are analyzed by sqlglot,
dplyneage’s one Python dependency — install the reticulate package to
enable that engine, and sqlglot itself is provisioned automatically the
first time it’s needed. See
[`vignette("python-integration")`](https://tgerke.github.io/dplyneage/articles/python-integration.md)
if you manage your own Python environment.

## Your first lineage diagram

Let’s create a small in-memory DuckDB database to work with:

``` r

library(dplyneage)
library(dplyr)
library(duckdb)

con <- dbConnect(duckdb(), ":memory:")

customers <- tibble(
  id = 1:5,
  name = c("Alice", "Bob", "Charlie", "Diana", "Eve"),
  email = paste0(tolower(name), "@example.com")
)

orders <- tibble(
  order_id = 1:10,
  customer_id = rep(1:5, each = 2),
  amount = c(100, 150, 200, 75, 300, 125, 180, 90, 250, 160)
)

copy_to(con, customers, "customers", overwrite = TRUE)
copy_to(con, orders, "orders", overwrite = TRUE)
```

The simplest lineage there is — two columns selected from one table:

``` r

tbl(con, "customers") |>
  select(id, name) |>
  extract_lineage() |>
  lineage_flow(height = "300px")
```

Each output column connects back to the source column it came from. Try
dragging the tables around, zooming with the mouse wheel, and hovering a
column to highlight its connections.

## A realistic pipeline

Lineage becomes useful once transformations pile up. Here is a join
followed by an aggregation:

``` r

tbl(con, "customers") |>
  left_join(tbl(con, "orders"), by = c("id" = "customer_id")) |>
  group_by(id, name) |>
  summarise(total_spent = sum(amount, na.rm = TRUE), .groups = "drop") |>
  extract_lineage() |>
  lineage_flow(height = "400px")
```

Notice that `total_spent` traces back to `orders.amount` — not to
`customers`, even though `amount` appears unqualified in the generated
SQL. When you pass a dbplyr table, dplyneage doesn’t parse SQL at all:
it walks the pipeline’s own query tree, which records exactly which
table each column came from, so attribution is always right.

If a pipeline embeds raw SQL with
[`dbplyr::sql()`](https://dbplyr.tidyverse.org/reference/sql.html), the
query tree can’t see inside that string, so
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
hands the whole query to sqlglot instead (with a message). You can also
force a specific engine with `engine = "r"` or `engine = "sqlglot"` —
see
[`?extract_lineage`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md).

## Where lineage gets hard

These are the cases that break naive lineage tools. dplyneage handles
them because both engines resolve the full query structure rather than
pattern-matching column names: dbplyr pipelines through their query
tree, raw SQL through sqlglot’s lineage engine. We’ll use raw SQL here
to keep the examples compact.

### Tracing through CTEs

Columns are traced *through* intermediate CTEs back to the base tables —
`recent` is transparent, and `amount` correctly attributes to `orders`:

``` r

extract_lineage("
  WITH recent AS (
    SELECT customer_id, amount FROM orders WHERE order_date > '2024-01-01'
  )
  SELECT customer_id, SUM(amount) AS total FROM recent GROUP BY customer_id
") |>
  lineage_flow(height = "300px")
```

### Columns with multiple sources

A computed column can come from several tables at once. `COALESCE` over
a full join gets an edge from *both* sources:

``` r

extract_lineage("
  SELECT COALESCE(u.email, a.email) AS email
  FROM users u FULL JOIN archive a ON u.id = a.id
") |>
  lineage_flow(height = "300px")
```

The same applies to arithmetic across tables (`o.amount * r.rate`),
`CASE` expressions, and both branches of a `UNION`. dbplyr pipelines get
the same treatment: a
[`full_join()`](https://dplyr.tidyverse.org/reference/mutate-joins.html)
key column traces to both sides, and a
[`union_all()`](https://dplyr.tidyverse.org/reference/setops.html)
column to every branch.

### Expanding `SELECT *`

With a schema available, `SELECT *` expands to real columns. dbplyr
input never needs a schema — the pipeline itself knows its columns — but
for raw SQL, pass one yourself:

``` r

extract_lineage(
  "SELECT * FROM customers",
  schema = list(customers = c("id", "name", "email"))
) |>
  lineage_flow(height = "300px")
```

## Raw SQL and schemas

As the examples above show,
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
accepts a SQL string directly — useful for auditing queries you didn’t
write in R. Two things to know:

- **Qualified columns** (`o.amount`) always resolve correctly, schema or
  not.
- **Unqualified columns** need a schema to be attributed with certainty.
  Pass a named list mapping each table to its columns:

``` r

extract_lineage(
  "SELECT c.name, order_date
   FROM customers c JOIN orders o ON c.id = o.customer_id",
  schema = list(
    customers = c("id", "name", "email"),
    orders = c("order_id", "customer_id", "order_date", "amount")
  )
) |>
  lineage_flow(height = "300px")
```

Without a schema, `SELECT *` cannot be expanded and produces a warning
rather than a silently empty diagram.

Queries in other SQL dialects work by setting `dialect`:

``` r

extract_lineage(query, dialect = "postgres")
extract_lineage(query, dialect = "snowflake")
```

## Local data frames

[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
reads lineage from a *lazy* query — the tree dbplyr builds up before
anything touches the database. A pipeline on a plain tibble has no such
tree: dplyr executes each verb immediately, so by the time you could ask
about lineage, only the result is left.

The workaround is one line.
[`dbplyr::memdb_frame()`](https://dbplyr.tidyverse.org/reference/memdb.html)
puts the data in a throwaway in-memory SQLite database (install the
RSQLite package once) and hands back a lazy table, so the identical
pipeline becomes traceable:

``` r

sales <- dbplyr::memdb_frame(
  customer_id = c(1, 1, 2),
  amount = c(100, 250, 40),
  .name = "sales"
)

sales |>
  group_by(customer_id) |>
  summarise(total = sum(amount, na.rm = TRUE)) |>
  extract_lineage() |>
  lineage_flow(height = "300px")
```

For a data frame you already have,
`copy_to(dbplyr::memdb(), df, name = "df")` does the same copy. Lineage
depends only on the pipeline’s structure, never on the data, so for
large frames copying a slice is enough —
`copy_to(dbplyr::memdb(), head(df), name = "df")` yields the same
diagram as copying every row.

The duckdb connection from earlier in this vignette works just as well
(`copy_to(con, df)`);
[`memdb_frame()`](https://dbplyr.tidyverse.org/reference/memdb.html) is
simply the fastest route when no connection exists yet.

## Building diagrams by hand

For documentation or design sketches, skip extraction entirely and build
the diagram yourself:

``` r

nodes <- list(
  create_table_node(
    table_name = "customers",
    columns = c("id", "name", "email"),
    x = 0, y = 100,
    table_type = "source"
  ),
  create_table_node(
    table_name = "customer_summary",
    columns = c("customer_id", "full_name", "contact"),
    x = 500, y = 100,
    table_type = "target"
  )
)

edges <- list(
  create_column_edge("customers", "id", "customer_summary", "customer_id"),
  create_column_edge("customers", "name", "customer_summary", "full_name"),
  create_column_edge("customers", "email", "customer_summary", "contact")
)

lineage_flow(nodes, edges, height = "300px")
```

Nodes come in three types — `"source"` (blue), `"transform"` (orange),
and `"target"` (green) — and edges accept a `label` (e.g. `"SUM()"`) and
`animated = TRUE` for emphasis.
[`lineage_example()`](https://tgerke.github.io/dplyneage/reference/lineage_example.md)
renders a complete hand-built diagram you can use as a template.

## Exporting lineage

Diagrams answer questions interactively; sometimes you need the same
lineage as plain data. Two exporters cover the common cases.

[`lineage_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md)
serializes the nodes, edges, and metadata to a small, stable JSON
document. Because the output is deterministic, you can commit it
alongside your pipeline code and let CI diff it: if a refactor silently
changes where a column comes from, the diff shows it before it ships. It
is also the natural handoff format for data catalogs or anything
scriptable with jq.

``` r

lineage <- tbl(con, "customers") |>
  left_join(tbl(con, "orders"), by = c("id" = "customer_id")) |>
  group_by(id, name) |>
  summarise(total_spent = sum(amount, na.rm = TRUE), .groups = "drop") |>
  extract_lineage()

lineage_json(lineage)
#> {
#>   "metadata": {
#>     "sql": "SELECT id, \"name\", SUM(amount) AS total_spent\nFROM (\n  SELECT customers.*, order_id, amount\n  FROM customers\n  LEFT JOIN orders\n    ON (customers.id = orders.customer_id)\n) AS q01\nGROUP BY id, \"name\"",
#>     "dialect": "duckdb",
#>     "engine": "r",
#>     "node_count": 3,
#>     "edge_count": 3
#>   },
#>   "nodes": [
#>     {
#>       "id": "customers",
#>       "type": "source",
#>       "columns": ["id", "name"]
#>     },
#>     {
#>       "id": "orders",
#>       "type": "source",
#>       "columns": ["amount"]
#>     },
#>     {
#>       "id": "output",
#>       "type": "target",
#>       "columns": ["id", "name", "total_spent"]
#>     }
#>   ],
#>   "edges": [
#>     {
#>       "source": "customers",
#>       "source_column": "id",
#>       "target": "output",
#>       "target_column": "id",
#>       "transformation": "identity",
#>       "expression": "id"
#>     },
#>     {
#>       "source": "customers",
#>       "source_column": "name",
#>       "target": "output",
#>       "target_column": "name",
#>       "transformation": "identity",
#>       "expression": "name"
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

[`lineage_graphml()`](https://tgerke.github.io/dplyneage/reference/lineage_graphml.md)
writes GraphML, the XML format that graph tools speak: igraph, Gephi,
and yEd all open it directly. Every column becomes its own node, which
is what makes real graph queries possible. The classic one is impact
analysis — “if `orders.amount` changes, which outputs are affected?” —
or its reverse, tracing an output back to every source column that feeds
it:

``` r

path <- tempfile(fileext = ".graphml")
lineage_graphml(lineage, path)

g <- igraph::read_graph(path, format = "graphml")

# Everything upstream of total_spent
igraph::subcomponent(g, "output.total_spent", mode = "in")
#> + 2/6 vertices, named, from f916e50:
#> [1] output.total_spent orders.amount

# Everything downstream of orders.amount
igraph::subcomponent(g, "orders.amount", mode = "out")
#> + 2/6 vertices, named, from f916e50:
#> [1] orders.amount      output.total_spent
```

Both functions return the serialized string when called without `path`,
so they compose in pipes and tests.

## Next steps

- [`vignette("python-integration")`](https://tgerke.github.io/dplyneage/articles/python-integration.md)
  explains how the Python dependency is managed, and how to use your own
  environment
- The [function
  reference](https://tgerke.github.io/dplyneage/reference/) documents
  every argument
- Found a query that traces incorrectly? Please [open an
  issue](https://github.com/tgerke/dplyneage/issues) with the SQL
