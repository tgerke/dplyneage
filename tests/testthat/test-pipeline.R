# Multi-model pipeline stitching: extract_lineage() on a named list.
# lazy_frame() fixtures cover the stitching logic engine-free; one duckdb
# test exercises the realistic materialized-layer flow.

skip_if_no_r_engine <- function() {
  testthat::skip_if_not_installed("dplyr")
  testthat::skip_if_not_installed("dbplyr", "2.5.0")
}

# silver aggregates orders; gold reads the materialized silver table
pipeline_fixture <- function() {
  silver <- dbplyr::lazy_frame(
    order_id = 1L, customer_id = 1L, amount = 1,
    .name = "orders"
  ) |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total_spent = sum(amount, na.rm = TRUE))

  gold <- dbplyr::lazy_frame(
    customer_id = 1L, total_spent = 1,
    .name = "silver"
  ) |>
    dplyr::mutate(big_spender = total_spent > 100)

  list(silver = silver, gold = gold)
}

test_that("a named list stitches models into one multi-hop graph", {
  skip_if_no_r_engine()

  lineage <- extract_lineage(pipeline_fixture())

  expect_s3_class(lineage, "dplyneage_lineage")
  expect_identical(node_ids(lineage), c("gold", "orders", "silver"))
  expect_edges(lineage, c(
    "orders.customer_id -> customer_id",
    "orders.amount -> total_spent",
    "silver.customer_id -> customer_id",
    "silver.total_spent -> total_spent",
    "silver.total_spent -> big_spender"
  ))

  types <- vapply(lineage$nodes, function(n) n$data$tableType, character(1))
  names(types) <- vapply(lineage$nodes, function(n) n$id, character(1))
  expect_identical(unname(types["orders"]), "source")
  expect_identical(unname(types["silver"]), "transform")
  expect_identical(unname(types["gold"]), "target")
})

test_that("stitched graphs support transitive impact analysis", {
  skip_if_no_r_engine()

  lineage <- extract_lineage(pipeline_fixture())

  expect_identical(
    lineage_upstream(lineage, "gold.big_spender"),
    c("orders.amount", "silver.total_spent")
  )
  expect_identical(
    lineage_downstream(lineage, "orders.amount"),
    c("gold.big_spender", "gold.total_spent", "silver.total_spent")
  )
})

test_that("models advance one layer per hop, left to right", {
  skip_if_no_r_engine()

  lineage <- extract_lineage(pipeline_fixture())

  xs <- vapply(lineage$nodes, function(n) n$position$x, numeric(1))
  names(xs) <- vapply(lineage$nodes, function(n) n$id, character(1))
  expect_lt(xs[["orders"]], xs[["silver"]])
  expect_lt(xs[["silver"]], xs[["gold"]])
})

test_that("columns read downstream but absent from a model's output appear", {
  skip_if_no_r_engine()

  models <- pipeline_fixture()
  # gold also reads a column silver's select list never mentions
  models$gold <- dbplyr::lazy_frame(
    customer_id = 1L, total_spent = 1, loaded_at = 1L,
    .name = "silver"
  ) |>
    dplyr::transmute(customer_id, loaded_at)

  lineage <- extract_lineage(models)

  expect_in("loaded_at", node_columns(lineage, "silver"))
})

test_that("pipeline metadata records per-model sql and engines", {
  skip_if_no_r_engine()

  lineage <- extract_lineage(pipeline_fixture())

  expect_identical(lineage$metadata$engine, "r")
  expect_named(lineage$metadata$models, c("silver", "gold"))
  expect_match(lineage$metadata$models$silver$sql, "SUM")
  expect_identical(lineage$metadata$node_count, 3L)
  expect_identical(lineage$metadata$edge_count, 5L)
})

test_that("stitched lineage prints and exports", {
  skip_if_no_r_engine()

  lineage <- extract_lineage(pipeline_fixture())

  expect_snapshot(print(lineage))

  parsed <- jsonlite::fromJSON(lineage_json(lineage), simplifyVector = FALSE)
  ids <- vapply(parsed$nodes, function(n) n$id, character(1))
  types <- vapply(parsed$nodes, function(n) n$type, character(1))
  expect_identical(types[ids == "silver"], "transform")
})

test_that("unnamed, partially named, and duplicated lists are rejected", {
  skip_if_no_r_engine()

  q <- pipeline_fixture()$silver
  expect_error(extract_lineage(list(q)), "named list")
  expect_error(extract_lineage(list(a = q, q)), "named list")
  expect_error(extract_lineage(list(a = q, a = q)), "named list")
  expect_error(extract_lineage(list()), "named list")
})

test_that("a model reading a same-named table errors clearly", {
  skip_if_no_r_engine()

  models <- list(
    orders = dbplyr::lazy_frame(amount = 1, .name = "orders") |>
      dplyr::mutate(doubled = amount * 2)
  )
  expect_error(extract_lineage(models), "same name")
})

test_that("a duckdb medallion pipeline stitches end to end", {
  testthat::skip_if_not_installed("dplyr")
  testthat::skip_if_not_installed("dbplyr", "2.5.0")
  testthat::skip_if_not_installed("duckdb")
  testthat::skip_if_not_installed("DBI")
  testthat::skip_if_not_installed("withr")

  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "orders", data.frame(
    order_id = 1:4, customer_id = c(1L, 1L, 2L, 2L),
    amount = c(10, 20, 30, 40)
  ))

  silver <- dplyr::tbl(con, "orders") |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total_spent = sum(amount, na.rm = TRUE), .groups = "drop")
  dplyr::compute(silver, name = "silver", temporary = TRUE)
  gold <- dplyr::tbl(con, "silver") |>
    dplyr::mutate(big_spender = total_spent > 25)

  lineage <- extract_lineage(list(silver = silver, gold = gold))

  expect_identical(node_ids(lineage), c("gold", "orders", "silver"))
  expect_edges(lineage, c(
    "orders.customer_id -> customer_id",
    "orders.amount -> total_spent",
    "silver.customer_id -> customer_id",
    "silver.total_spent -> total_spent",
    "silver.total_spent -> big_spender"
  ))
})

test_that("indirect edges stitch across models and extend traversal", {
  skip_if_no_r_engine()

  silver <- dbplyr::lazy_frame(
    order_id = 1L, customer_id = 1L, amount = 1,
    .name = "orders"
  ) |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total_spent = sum(amount, na.rm = TRUE))
  gold <- dbplyr::lazy_frame(
    customer_id = 1L, total_spent = 1, loaded_at = 1L,
    .name = "silver"
  ) |>
    dplyr::filter(loaded_at > 0) |>
    dplyr::transmute(customer_id)

  lineage <- extract_lineage(
    list(silver = silver, gold = gold),
    include_indirect = TRUE
  )

  edges <- lineage_edges(lineage)
  filters <- edges[edges$transformation == "filter", ]
  expect_identical(filters$source_table, "silver")
  expect_identical(filters$source_column, "loaded_at")
  expect_identical(filters$target_table, "gold")

  # The filter column appears on the silver node even though silver's own
  # select list never mentions it, and impact analysis sees through it
  expect_in("loaded_at", node_columns(lineage, "silver"))
  expect_in(
    "silver.loaded_at",
    lineage_upstream(lineage, "gold.customer_id")
  )
})
