# Skip helpers ---------------------------------------------------------

skip_if_no_sqlglot <- function() {
  testthat::skip_if_not_installed("reticulate")
  available <- tryCatch(has_sqlglot(), error = function(e) FALSE)
  testthat::skip_if_not(available, "Python sqlglot is not available")
}

# Fixtures --------------------------------------------------------------

# The shape produced by the Python lineage module: columns with
# output_name/expression/sources. Feed to convert_lineage_to_graph()
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
        type = "identity",
        sources = list(list(table = "customers", column_name = "customer_id"))
      ),
      list(
        output_name = "total_spent",
        expression = "SUM(amount)",
        type = "aggregation",
        sources = list(list(table = "orders", column_name = "amount"))
      )
    ),
    sql = "SELECT ...",
    dialect = "duckdb"
  )
}

# Assertion helpers -----------------------------------------------------

# Flatten a lineage object's edges into a sorted data frame of
# source_table.source_col -> target_col strings for exact-set comparison
edge_set <- function(lineage) {
  if (length(lineage$edges) == 0) {
    return(character(0))
  }
  sort(vapply(
    lineage$edges,
    function(e) paste0(e$source, ".", e$sourceHandle, " -> ", e$targetHandle),
    character(1)
  ))
}

expect_edges <- function(lineage, expected) {
  testthat::expect_identical(edge_set(lineage), sort(expected))
}

node_ids <- function(lineage) {
  sort(vapply(lineage$nodes, function(n) n$id, character(1)))
}

node_columns <- function(lineage, id) {
  for (n in lineage$nodes) {
    if (n$id == id) {
      return(sort(unlist(n$data$columns)))
    }
  }
  NULL
}
