# fixture_lineage() lives in helper-lineage.R and is shared with
# test-export.R

test_that("graph conversion groups columns into source and output nodes", {
  graph <- convert_lineage_to_graph(fixture_lineage())

  expect_identical(node_ids(graph), c("customers", "orders", "output"))
  expect_identical(node_columns(graph, "customers"), "customer_id")
  expect_identical(node_columns(graph, "orders"), "amount")
  expect_identical(node_columns(graph, "output"), c("customer_id", "total_spent"))

  types <- vapply(graph$nodes, function(n) n$data$tableType, character(1))
  expect_identical(sort(unique(types)), c("source", "target"))
})

test_that("graph conversion creates one edge per column source", {
  graph <- convert_lineage_to_graph(fixture_lineage())

  expect_edges(graph, c(
    "customers.customer_id -> customer_id",
    "orders.amount -> total_spent"
  ))
})

test_that("multi-source columns produce multiple edges", {
  lineage <- fixture_lineage()
  lineage$columns[[2]]$sources <- list(
    list(table = "orders", column_name = "amount"),
    list(table = "customers", column_name = "discount")
  )

  graph <- convert_lineage_to_graph(lineage)

  expect_edges(graph, c(
    "customers.customer_id -> customer_id",
    "customers.discount -> total_spent",
    "orders.amount -> total_spent"
  ))
})

test_that("sources with missing tables fall back to an 'unknown' node", {
  lineage <- fixture_lineage()
  lineage$columns[[1]]$sources <- list(list(table = NULL, column_name = "customer_id"))

  graph <- convert_lineage_to_graph(lineage)

  expect_true("unknown" %in% node_ids(graph))
})

test_that("NA and empty table names group and connect under 'unknown'", {
  lineage <- fixture_lineage()
  lineage$columns[[1]]$sources <- list(list(table = NA, column_name = "customer_id"))
  lineage$columns[[2]]$sources <- list(list(table = "", column_name = "amount"))

  graph <- convert_lineage_to_graph(lineage)

  expect_identical(node_ids(graph), c("output", "unknown"))
  expect_edges(graph, c(
    "unknown.customer_id -> customer_id",
    "unknown.amount -> total_spent"
  ))
})

test_that("a source table named 'output' keeps its own node", {
  lineage <- fixture_lineage()
  lineage$columns[[1]]$sources <- list(
    list(table = "output", column_name = "customer_id")
  )

  graph <- convert_lineage_to_graph(lineage)

  expect_identical(node_ids(graph), c("orders", "output", "output_"))
  expect_edges(graph, c(
    "output.customer_id -> customer_id",
    "orders.amount -> total_spent"
  ))
  targets <- vapply(graph$edges, function(e) e$target, character(1))
  expect_identical(unique(targets), "output_")

  types <- vapply(graph$nodes, function(n) n$data$tableType, character(1))
  names(types) <- vapply(graph$nodes, function(n) n$id, character(1))
  expect_identical(unname(types["output"]), "source")
  expect_identical(unname(types["output_"]), "target")
})

test_that("columns without sources still appear in the output node", {
  lineage <- fixture_lineage()
  lineage$columns[[2]]$sources <- list()

  graph <- convert_lineage_to_graph(lineage)

  expect_identical(node_columns(graph, "output"), c("customer_id", "total_spent"))
  expect_edges(graph, "customers.customer_id -> customer_id")
})

test_that("metadata records the analyzed SQL and counts", {
  graph <- convert_lineage_to_graph(fixture_lineage())

  expect_identical(graph$metadata$sql, "SELECT ...")
  expect_identical(graph$metadata$dialect, "duckdb")
  expect_identical(graph$metadata$node_count, 3L)
  expect_identical(graph$metadata$edge_count, 2L)
})
