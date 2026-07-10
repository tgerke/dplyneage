# Integration tests for the sqlglot-backed extraction. Each case here was
# chosen because a naive AST heuristic gets it wrong; sqlglot.lineage must
# produce these exact edge sets.

test_that("extract_lineage rejects non-SQL input", {
  skip_if_no_sqlglot()
  expect_error(extract_lineage(42), "character string or a dbplyr lazy table")
  expect_error(extract_lineage(list()), "character string or a dbplyr lazy table")
})

test_that("simple single-table select", {
  skip_if_no_sqlglot()

  lineage <- extract_lineage("SELECT customer_id, name FROM customers")

  expect_edges(lineage, c(
    "customers.customer_id -> customer_id",
    "customers.name -> name"
  ))
  expect_identical(lineage$metadata$sql, "SELECT customer_id, name FROM customers")
  expect_identical(lineage$metadata$dialect, "duckdb")
})

test_that("unqualified columns in a join resolve via schema", {
  skip_if_no_sqlglot()

  lineage <- extract_lineage(
    "SELECT c.name, order_date FROM customers AS c JOIN orders AS o ON c.id = o.customer_id",
    schema = list(
      customers = c("id", "name"),
      orders = c("customer_id", "order_date")
    )
  )

  # order_date is unqualified in the SQL but belongs to orders
  expect_edges(lineage, c(
    "customers.name -> name",
    "orders.order_date -> order_date"
  ))
})

test_that("CTEs are traced through to base tables", {
  skip_if_no_sqlglot()

  lineage <- extract_lineage("
    WITH recent AS (
      SELECT customer_id, amount FROM orders WHERE order_date > 2024
    )
    SELECT customer_id, SUM(amount) AS total FROM recent GROUP BY customer_id
  ")

  expect_edges(lineage, c(
    "orders.customer_id -> customer_id",
    "orders.amount -> total"
  ))
  # the CTE itself must not appear as a table node
  expect_false("recent" %in% node_ids(lineage))
})

test_that("computed columns keep all their source tables", {
  skip_if_no_sqlglot()

  lineage <- extract_lineage(
    "SELECT o.amount * t.rate AS usd
     FROM orders o JOIN fx t ON o.cur = t.cur"
  )

  expect_edges(lineage, c(
    "orders.amount -> usd",
    "fx.rate -> usd"
  ))
})

test_that("COALESCE across a full join keeps both sources", {
  skip_if_no_sqlglot()

  lineage <- extract_lineage(
    "SELECT COALESCE(a.email, b.email) AS email
     FROM users a FULL JOIN archive b ON a.id = b.id"
  )

  expect_edges(lineage, c(
    "users.email -> email",
    "archive.email -> email"
  ))
})

test_that("UNION keeps both branches", {
  skip_if_no_sqlglot()

  lineage <- extract_lineage("SELECT id FROM t1 UNION ALL SELECT id FROM t2")

  expect_edges(lineage, c(
    "t1.id -> id",
    "t2.id -> id"
  ))
})

test_that("SELECT * expands when a schema is supplied", {
  skip_if_no_sqlglot()

  lineage <- extract_lineage(
    "SELECT * FROM customers",
    schema = list(customers = c("id", "name"))
  )

  expect_edges(lineage, c(
    "customers.id -> id",
    "customers.name -> name"
  ))
})

test_that("SELECT * without a schema warns instead of failing silently", {
  skip_if_no_sqlglot()

  expect_warning(
    lineage <- extract_lineage("SELECT * FROM customers"),
    "schema"
  )
  expect_length(lineage$edges, 0)
})

test_that("schema-qualified tables stay distinct nodes", {
  skip_if_no_sqlglot()

  lineage <- extract_lineage(
    "SELECT o.amount, r.status
     FROM stg.orders o JOIN raw.orders r ON o.order_id = r.order_id"
  )

  expect_edges(lineage, c(
    "stg.orders.amount -> amount",
    "raw.orders.status -> status"
  ))
  expect_identical(node_ids(lineage), c("output", "raw.orders", "stg.orders"))
})

test_that("qualified schema keys expand stars and attribute columns", {
  skip_if_no_sqlglot()

  lineage <- extract_lineage(
    "SELECT * FROM stg.orders",
    schema = list("stg.orders" = c("order_id", "amount"))
  )

  expect_edges(lineage, c(
    "stg.orders.order_id -> order_id",
    "stg.orders.amount -> amount"
  ))
})

test_that("mixed-depth schemas are dropped with a warning", {
  skip_if_no_sqlglot()

  expect_warning(
    extract_lineage(
      "SELECT amount FROM stg.orders",
      schema = list("stg.orders" = "amount", customers = "id")
    ),
    "uniform nesting depth"
  )
})

test_that("literal columns appear in output without lineage edges", {
  skip_if_no_sqlglot()

  lineage <- extract_lineage("SELECT 1 AS flag, name FROM customers")

  expect_edges(lineage, "customers.name -> name")
  expect_true("flag" %in% node_columns(lineage, "output"))
})

test_that("dialect is forwarded to sqlglot", {
  skip_if_no_sqlglot()

  # Postgres-style cast syntax parses under the postgres dialect
  lineage <- extract_lineage(
    "SELECT amount::text AS amount_chr FROM orders",
    dialect = "postgres"
  )

  expect_edges(lineage, "orders.amount -> amount_chr")
})
