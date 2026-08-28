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

test_that("table names traverse stitched graphs", {
  skip_if_no_r_engine()

  lineage <- extract_lineage(pipeline_fixture())

  expect_identical(
    lineage_downstream(lineage, "orders"),
    c(
      "gold.big_spender", "gold.customer_id", "gold.total_spent",
      "silver.customer_id", "silver.total_spent"
    )
  )
  expect_identical(
    lineage_upstream(lineage, "gold"),
    c(
      "orders.amount", "orders.customer_id",
      "silver.customer_id", "silver.total_spent"
    )
  )
})

test_that("a qualified model id resolves as a table name", {
  skip_if_no_r_engine()

  models <- pipeline_fixture()
  gold_qualified <- dbplyr::lazy_frame(
    customer_id = 1L, total_spent = 1,
    .name = "main.silver"
  ) |>
    dplyr::mutate(big_spender = total_spent > 100)
  lineage <- extract_lineage(
    list("main.silver" = models$silver, gold = gold_qualified)
  )

  # No node "main" declares a column "silver", so the string dispatches
  # as the table id
  expect_identical(
    lineage_upstream(lineage, "main.silver"),
    c("orders.amount", "orders.customer_id")
  )
})

test_that("lineage_unused surfaces unconsumed intermediate outputs", {
  skip_if_no_r_engine()

  models <- pipeline_fixture()
  # gold drops customer_id, stranding silver.customer_id and, with it,
  # the base column that only fed it
  gold <- dbplyr::lazy_frame(
    customer_id = 1L, total_spent = 1,
    .name = "silver"
  ) |>
    dplyr::transmute(big_spender = total_spent > 100)
  lineage <- extract_lineage(list(silver = models$silver, gold = gold))

  unused <- lineage_unused(lineage)
  expect_identical(unused$table, c("orders", "silver"))
  expect_identical(unused$column, c("customer_id", "customer_id"))
  expect_identical(unused$table_type, c("source", "transform"))

  expect_identical(nrow(lineage_unused(extract_lineage(models))), 0L)
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
  expect_identical(lineage$metadata$models$silver$dialect, "duckdb")
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

test_that("a qualified source resembling a model warns instead of silently disconnecting", {
  skip_if_no_r_engine()

  models <- pipeline_fixture()
  gold_qualified <- dbplyr::lazy_frame(
    customer_id = 1L, total_spent = 1,
    .name = "main.silver"
  ) |>
    dplyr::mutate(big_spender = total_spent > 100)

  expect_warning(
    extract_lineage(list(silver = models$silver, gold = gold_qualified)),
    "main.silver"
  )
})

test_that("a case-mismatched source resembling a model warns", {
  skip_if_no_r_engine()

  models <- pipeline_fixture()
  gold_upper <- dbplyr::lazy_frame(
    customer_id = 1L, total_spent = 1,
    .name = "SILVER"
  ) |>
    dplyr::mutate(big_spender = total_spent > 100)

  expect_warning(
    extract_lineage(list(silver = models$silver, gold = gold_upper)),
    "SILVER"
  )
})

test_that("qualified model names stitch by exact match, without warning", {
  skip_if_no_r_engine()

  models <- pipeline_fixture()
  gold_qualified <- dbplyr::lazy_frame(
    customer_id = 1L, total_spent = 1,
    .name = "main.silver"
  ) |>
    dplyr::mutate(big_spender = total_spent > 100)

  expect_no_warning(
    lineage <- extract_lineage(
      list("main.silver" = models$silver, gold = gold_qualified)
    )
  )
  expect_in("main.silver", node_ids(lineage))
  expect_in(
    "orders.amount",
    lineage_upstream(lineage, "gold.big_spender")
  )
})

test_that("raw-vs-model name overlap does not warn when the columns differ", {
  skip_if_no_r_engine()

  # The canonical raw -> model pattern: a model named for the entity it
  # cleans, reading a qualified raw table with different columns
  clean <- dbplyr::lazy_frame(
    order_id = 1L, amount = 1,
    .name = "raw.orders"
  ) |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE))

  expect_no_warning(extract_lineage(list(orders = clean)))
})

test_that("pipeline models keep one indirect edge per pair with all kinds", {
  skip_if_no_r_engine()

  report <- dbplyr::lazy_frame(a = 1, b = 2, .name = "t1") |>
    dplyr::filter(b > 0) |>
    dbplyr::window_order(b) |>
    dplyr::mutate(rn = dplyr::row_number()) |>
    dplyr::select(a, rn)

  lineage <- extract_lineage(list(report = report), include_indirect = TRUE)

  edge <- Filter(
    function(e) e$sourceHandle == "b" && e$targetHandle == "a",
    lineage$edges
  )
  expect_length(edge, 1L)
  expect_setequal(edge[[1]]$data$transformations, c("filter", "sort"))
  expect_identical(
    edge[[1]]$data$transformation,
    edge[[1]]$data$transformations[[1]]
  )
})

test_that("labels propagate across stitched models, hop by hop", {
  skip_if_no_r_engine()

  lineage <- extract_lineage(
    pipeline_fixture(),
    labels = list(
      orders = c(customer_id = "Customer id"),
      gold = c(big_spender = "Spent over 100")
    )
  )

  by_id <- stats::setNames(
    lineage$nodes,
    vapply(lineage$nodes, function(n) n$id, character(1))
  )
  # orders -> silver -> gold, two identity hops
  expect_identical(
    by_id$silver$data$columnLabels,
    list(customer_id = "Customer id")
  )
  # gold's own labels= entry covers the computed column propagation
  # can't reach; total_spent is aggregated upstream and stays bare
  expect_identical(
    by_id$gold$data$columnLabels,
    list(big_spender = "Spent over 100", customer_id = "Customer id")
  )
})
