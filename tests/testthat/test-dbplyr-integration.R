# End-to-end tests: dplyr pipeline -> dbplyr SQL -> sqlglot lineage,
# including automatic schema harvesting from the DuckDB connection

local_duckdb <- function(env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)

  DBI::dbWriteTable(con, "customers", data.frame(
    customer_id = 1:3,
    first_name = c("Alice", "Bob", "Cleo"),
    email = c("a@x.com", "b@x.com", "c@x.com"),
    stringsAsFactors = FALSE
  ))
  DBI::dbWriteTable(con, "orders", data.frame(
    order_id = 1:6,
    customer_id = rep(1:3, 2),
    amount = c(10, 20, 30, 40, 50, 60),
    order_date = 1:6
  ))
  con
}

skip_if_no_db_stack <- function() {
  skip_if_no_sqlglot()
  testthat::skip_if_not_installed("dplyr")
  testthat::skip_if_not_installed("dbplyr")
  testthat::skip_if_not_installed("duckdb")
  testthat::skip_if_not_installed("DBI")
  testthat::skip_if_not_installed("withr")
}

test_that("a joined + summarised pipeline yields correct column lineage", {
  skip_if_no_db_stack()
  con <- local_duckdb()

  query <- dplyr::tbl(con, "customers") |>
    dplyr::left_join(dplyr::tbl(con, "orders"), by = "customer_id") |>
    dplyr::group_by(customer_id, first_name) |>
    dplyr::summarise(
      total_spent = sum(amount, na.rm = TRUE),
      first_order = min(order_date, na.rm = TRUE),
      .groups = "drop"
    )

  lineage <- extract_lineage(query)

  # Schema harvested from the connection attributes each column to the
  # correct base table even where dbplyr leaves columns unqualified
  expect_edges(lineage, c(
    "customers.customer_id -> customer_id",
    "customers.first_name -> first_name",
    "orders.amount -> total_spent",
    "orders.order_date -> first_order"
  ))
  expect_identical(node_ids(lineage), c("customers", "orders", "output"))
})

test_that("renamed columns trace back to their origins", {
  skip_if_no_db_stack()
  con <- local_duckdb()

  query <- dplyr::tbl(con, "customers") |>
    dplyr::select(id = customer_id, contact = email)

  lineage <- extract_lineage(query)

  expect_edges(lineage, c(
    "customers.customer_id -> id",
    "customers.email -> contact"
  ))
})

test_that("an explicit schema overrides harvesting", {
  skip_if_no_db_stack()
  con <- local_duckdb()

  query <- dplyr::tbl(con, "customers") |>
    dplyr::select(customer_id)

  lineage <- extract_lineage(
    query,
    schema = list(customers = c("customer_id", "first_name", "email"))
  )

  expect_edges(lineage, "customers.customer_id -> customer_id")
})

test_that("the R and sqlglot engines agree on real pipelines", {
  skip_if_no_db_stack()
  con <- local_duckdb()

  queries <- list(
    joined_summarised = dplyr::tbl(con, "customers") |>
      dplyr::left_join(dplyr::tbl(con, "orders"), by = "customer_id") |>
      dplyr::group_by(customer_id, first_name) |>
      dplyr::summarise(
        total_spent = sum(amount, na.rm = TRUE),
        first_order = min(order_date, na.rm = TRUE),
        .groups = "drop"
      ),
    renamed = dplyr::tbl(con, "customers") |>
      dplyr::select(id = customer_id, contact = email),
    chained_mutate = dplyr::tbl(con, "orders") |>
      dplyr::transmute(subtotal = amount + order_id) |>
      dplyr::mutate(total = subtotal * 2),
    unioned = dplyr::union_all(
      dplyr::transmute(dplyr::tbl(con, "customers"), id = customer_id),
      dplyr::transmute(dplyr::tbl(con, "orders"), id = order_id)
    )
  )

  for (nm in names(queries)) {
    r_lineage <- extract_lineage(queries[[nm]], engine = "r")
    sqlglot_lineage <- extract_lineage(queries[[nm]], engine = "sqlglot")
    expect_identical(edge_set(r_lineage), edge_set(sqlglot_lineage), label = nm)
    expect_identical(node_ids(r_lineage), node_ids(sqlglot_lineage), label = nm)
  }
})

test_that("the engines agree on window functions with include_indirect", {
  skip_if_no_db_stack()
  con <- local_duckdb()

  # Single-SELECT shapes only. One known asymmetry is out of scope:
  # dbplyr-generated subqueries hit the sqlglot engine's derived-table
  # skip in _indirect_refs. Transformation kinds are not compared either:
  # sqlglot classifies from rendered SQL (LAG and cumulative SUM are
  # AggFunc there) while the R engine classifies from the dplyr verb.
  queries <- list(
    windowed = dplyr::tbl(con, "orders") |>
      dplyr::group_by(customer_id) |>
      dbplyr::window_order(order_date) |>
      dplyr::transmute(
        rn = dplyr::row_number(),
        total = sum(amount, na.rm = TRUE)
      ),
    filtered_window = dplyr::tbl(con, "orders") |>
      dplyr::filter(amount > 10) |>
      dplyr::group_by(customer_id) |>
      dbplyr::window_order(order_date) |>
      dplyr::transmute(rn = dplyr::row_number()),
    desc_lag = dplyr::tbl(con, "orders") |>
      dplyr::group_by(customer_id) |>
      dbplyr::window_order(dplyr::desc(order_date)) |>
      dplyr::mutate(prev = dplyr::lag(amount)),
    ungrouped_cumsum = dplyr::tbl(con, "orders") |>
      dbplyr::window_order(order_date) |>
      dplyr::transmute(cum = cumsum(amount)),
    no_window_control = dplyr::tbl(con, "orders") |>
      dplyr::group_by(customer_id) |>
      dplyr::mutate(bumped = amount + 1)
  )

  for (nm in names(queries)) {
    r_lineage <- extract_lineage(
      queries[[nm]],
      engine = "r", include_indirect = TRUE
    )
    sqlglot_lineage <- extract_lineage(
      queries[[nm]],
      engine = "sqlglot", include_indirect = TRUE
    )
    expect_identical(edge_set(r_lineage), edge_set(sqlglot_lineage), label = nm)
    expect_identical(node_ids(r_lineage), node_ids(sqlglot_lineage), label = nm)
  }
})

test_that("WITHIN GROUP ordered-set aggregates add no sort edges", {
  skip_if_no_sqlglot()
  testthat::skip_if_not_installed("dplyr")
  testthat::skip_if_not_installed("dbplyr", "2.5.0")

  # On postgres-style dialects median() renders as
  # PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amount); that ORDER BY is
  # an argument of the aggregate, not a result ordering (#17)
  query <- dbplyr::lazy_frame(
    customer_id = 1L, amount = 1.5,
    con = dbplyr::simulate_postgres(), .name = "orders"
  ) |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(med = median(amount, na.rm = TRUE))

  sql <- as.character(dbplyr::remote_query(query))
  expect_match(sql, "WITHIN GROUP", fixed = TRUE)

  sqlglot_lineage <- extract_lineage(
    sql,
    dialect = "postgres",
    schema = list(orders = c("customer_id", "amount")),
    include_indirect = TRUE
  )
  expect_edges(sqlglot_lineage, c(
    "orders.customer_id -> customer_id",
    "orders.amount -> med",
    "orders.customer_id -> med"
  ))

  r_lineage <- extract_lineage(query, engine = "r", include_indirect = TRUE)
  expect_identical(edge_set(sqlglot_lineage), edge_set(r_lineage))
})

test_that("the sqlglot path harvests column types from the connection", {
  skip_if_no_db_stack()
  con <- local_duckdb()

  lineage <- dplyr::tbl(con, "orders") |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE)) |>
    extract_lineage(engine = "sqlglot")

  orders <- Filter(function(n) n$id == "orders", lineage$nodes)[[1]]
  types <- orders$data$columnTypes
  # dbColumnInfo() reports duckdb types at R-type granularity
  expect_identical(types$amount, "numeric")
  expect_identical(types$customer_id, "integer")

  event <- jsonlite::fromJSON(
    lineage_openlineage(lineage, run_id = "x", event_time = "t"),
    simplifyVector = FALSE
  )
  fields <- event$inputs[[1]]$facets$schema$fields
  by_name <- stats::setNames(
    fields,
    vapply(fields, `[[`, character(1), "name")
  )
  expect_identical(by_name$amount$type, "numeric")
})

test_that("schema-qualified duckdb tables trace identically in both engines", {
  skip_if_no_db_stack()
  con <- local_duckdb()
  DBI::dbExecute(con, "CREATE SCHEMA stg")
  DBI::dbExecute(con, "CREATE TABLE stg.orders AS SELECT * FROM orders")

  query <- dplyr::tbl(con, DBI::Id("stg", "orders")) |>
    dplyr::select(order_id, amount)

  r_lineage <- extract_lineage(query, engine = "r")
  expect_edges(r_lineage, c(
    "stg.orders.order_id -> order_id",
    "stg.orders.amount -> amount"
  ))

  # The sqlglot path harvests the qualified table's schema via DBI::Id
  sqlglot_lineage <- extract_lineage(query, engine = "sqlglot")
  expect_identical(edge_set(sqlglot_lineage), edge_set(r_lineage))
  expect_identical(node_ids(sqlglot_lineage), node_ids(r_lineage))
})

test_that("engine = 'auto' takes the R fast path for lazy tables", {
  testthat::skip_if_not_installed("dplyr")
  testthat::skip_if_not_installed("dbplyr", "2.5.0")
  testthat::skip_if_not_installed("duckdb")
  testthat::skip_if_not_installed("DBI")
  testthat::skip_if_not_installed("withr")
  con <- local_duckdb()

  lineage <- dplyr::tbl(con, "customers") |>
    dplyr::select(customer_id) |>
    extract_lineage()

  expect_identical(lineage$metadata$engine, "r")
  expect_edges(lineage, "customers.customer_id -> customer_id")
})

test_that("unsupported constructs fall back to sqlglot with a message", {
  skip_if_no_db_stack()
  con <- local_duckdb()

  query <- dplyr::tbl(con, "orders") |>
    dplyr::transmute(order_id, bumped = dbplyr::sql("amount + 1"))

  expect_message(
    lineage <- extract_lineage(query),
    "Falling back to the sqlglot engine"
  )
  expect_identical(lineage$metadata$engine, "sqlglot")
  expect_edges(lineage, c(
    "orders.order_id -> order_id",
    "orders.amount -> bumped"
  ))
})

test_that("extract_lineage output pipes into lineage_flow", {
  skip_if_no_db_stack()
  con <- local_duckdb()

  w <- dplyr::tbl(con, "orders") |>
    dplyr::select(order_id, amount) |>
    extract_lineage() |>
    lineage_flow()

  expect_s3_class(w, "htmlwidget")
  expect_length(w$x$nodes, 2)
  expect_length(w$x$edges, 2)
})

skip_if_no_duckdb_stack <- function() {
  testthat::skip_if_not_installed("dplyr")
  testthat::skip_if_not_installed("dbplyr", "2.5.0")
  testthat::skip_if_not_installed("duckdb")
  testthat::skip_if_not_installed("DBI")
  testthat::skip_if_not_installed("withr")
}

test_that("copy_inline() frames trace as sourceless values", {
  skip_if_no_duckdb_stack()
  con <- local_duckdb()

  inline <- dbplyr::copy_inline(
    con,
    data.frame(customer_id = 1, region = "a", stringsAsFactors = FALSE)
  )

  # Bare values table: the columns are inlined literals with no base
  # table, matching how the sqlglot engine treats VALUES
  lineage <- extract_lineage(inline)
  expect_identical(lineage$metadata$engine, "r")
  expect_identical(edge_set(lineage), character(0))
  expect_identical(node_columns(lineage, "output"), c("customer_id", "region"))

  # Joined onto a real table, the real columns still trace and the
  # values columns stay sourceless instead of crashing the walk
  joined <- dplyr::tbl(con, "orders") |>
    dplyr::select(order_id, customer_id) |>
    dplyr::left_join(inline, by = "customer_id")
  lineage <- extract_lineage(joined)
  expect_identical(lineage$metadata$engine, "r")
  expect_edges(lineage, c(
    "orders.order_id -> order_id",
    "orders.customer_id -> customer_id"
  ))

  # The values-side join key has no sources; indirect collection must
  # cope rather than error
  lineage <- extract_lineage(joined, include_indirect = TRUE)
  expect_identical(lineage$metadata$engine, "r")
})
