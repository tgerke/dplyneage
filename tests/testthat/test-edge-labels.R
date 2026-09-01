labeled_edge <- function(from_column, to_column, expression) {
  edge <- create_column_edge(
    from_table = "orders",
    from_column = from_column,
    to_table = "output",
    to_column = to_column,
    label = truncate_label(expression)
  )
  edge$data <- list(expression = expression, transformation = "transformation")
  edge
}

test_that("sibling edges sharing an expression keep one label", {
  edges <- dedupe_edge_labels(list(
    labeled_edge("order_id", "avg_order", "total_spent/total_orders"),
    labeled_edge("amount", "avg_order", "total_spent/total_orders")
  ))

  expect_identical(edges[[1]]$label, "total_spent/total_orders")
  expect_null(edges[[2]]$label)
  expect_null(edges[[2]]$labelStyle)
  expect_null(edges[[2]]$labelBgStyle)
})

test_that("the full expression survives on every edge of the group", {
  edges <- dedupe_edge_labels(list(
    labeled_edge("order_id", "avg_order", "total_spent/total_orders"),
    labeled_edge("amount", "avg_order", "total_spent/total_orders")
  ))

  expect_identical(
    vapply(edges, function(e) e$data$expression, character(1)),
    rep("total_spent/total_orders", 2)
  )
})

test_that("differing sibling expressions join rather than drop", {
  edges <- dedupe_edge_labels(list(
    labeled_edge("a", "key", "coalesce(a)"),
    labeled_edge("b", "key", "coalesce(b)")
  ))

  expect_identical(edges[[1]]$label, "coalesce(a) | coalesce(b)")
  expect_null(edges[[2]]$label)
})

test_that("a joined label truncates to the widget budget", {
  edges <- dedupe_edge_labels(list(
    labeled_edge("a", "key", strrep("x", 30)),
    labeled_edge("b", "key", strrep("y", 30))
  ))

  expect_identical(nchar(edges[[1]]$label), 34L)
  expect_match(edges[[1]]$label, "…$")
})

test_that("edges into different output columns each keep their label", {
  edges <- dedupe_edge_labels(list(
    labeled_edge("amount", "total_spent", "sum(amount, na.rm = TRUE)"),
    labeled_edge("order_id", "total_orders", "n_distinct(order_id)")
  ))

  expect_identical(edges[[1]]$label, "sum(amount, na.rm = TRUE)")
  expect_identical(edges[[2]]$label, "n_distinct(order_id)")
})

test_that("unlabeled identity and indirect edges pass through untouched", {
  identity <- create_column_edge("customers", "email", "output", "email")
  indirect <- indirect_edge_for(
    list(table = "orders", column_name = "amount", kind = "filter"),
    "output",
    "email"
  )
  edges <- dedupe_edge_labels(list(identity, indirect))

  expect_identical(edges, list(identity, indirect))
})

test_that("dedupe_edge_labels handles an empty edge list", {
  expect_identical(dedupe_edge_labels(list()), list())
})

test_that("a multi-source computed column is labeled once end to end", {
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("dplyr")

  lineage <- dbplyr::tbl_lazy(
    data.frame(customer_id = 1, order_id = 1, amount = 1),
    name = "orders"
  ) |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(
      total_orders = dplyr::n_distinct(order_id),
      total_spent = sum(amount, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(avg_order = total_spent / total_orders) |>
    extract_lineage()

  into_avg <- Filter(
    function(e) identical(e$targetHandle, "avg_order"),
    lineage$edges
  )
  labels <- Filter(Negate(is.null), lapply(into_avg, function(e) e$label))

  expect_gt(length(into_avg), 1)
  expect_length(labels, 1)
})

test_that("a hand-built label with no expression behind it survives", {
  edge <- create_column_edge(
    from_table = "orders",
    from_column = "amount",
    to_table = "customer_summary",
    to_column = "total_spent",
    label = "SUM()"
  )

  expect_identical(dedupe_edge_labels(list(edge))[[1]]$label, "SUM()")
})
