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
