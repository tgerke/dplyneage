# convert_lineage_to_graph() consumes the shape produced by the Python
# lineage module: columns with output_name/expression/sources

fixture_lineage <- function() {
  list(
    tables = list(
      list(name = "customers", alias = NULL, qualified_name = "customers"),
      list(name = "orders", alias = NULL, qualified_name = "orders")
    ),
    columns = list(
      list(
        output_name = "customer_id",
        expression = "customer_id",
        sources = list(list(table = "customers", column_name = "customer_id"))
      ),
      list(
        output_name = "total_spent",
        expression = "SUM(amount)",
        sources = list(list(table = "orders", column_name = "amount"))
      )
    ),
    sql = "SELECT ...",
    dialect = "duckdb"
  )
}

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
  expect_identical(graph$metadata$edge_count, 2L)
})
