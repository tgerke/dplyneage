# Skip helpers ---------------------------------------------------------

skip_if_no_sqlglot <- function() {
  testthat::skip_if_not_installed("reticulate")
  available <- tryCatch(has_sqlglot(), error = function(e) FALSE)
  testthat::skip_if_not(available, "Python sqlglot is not available")
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
