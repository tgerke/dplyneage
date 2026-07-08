test_that("create_table_node builds the expected structure", {
  node <- create_table_node(
    table_name = "customers",
    columns = c("id", "name"),
    x = 10,
    y = 20,
    table_type = "source"
  )

  expect_identical(node$id, "customers")
  expect_identical(node$type, "tableNode")
  expect_identical(node$data$label, "customers")
  expect_identical(node$data$columns, c("id", "name"))
  expect_identical(node$data$tableType, "source")
  expect_identical(node$position, list(x = 10, y = 20))
  expect_true(node$draggable)
  expect_identical(node$sourcePosition, "right")
  expect_identical(node$targetPosition, "left")
})

test_that("create_table_node assigns colors by table type", {
  source_node <- create_table_node("a", "x", table_type = "source")
  transform_node <- create_table_node("b", "x", table_type = "transform")
  target_node <- create_table_node("c", "x", table_type = "target")

  expect_identical(source_node$data$colors$border, "#3b82f6")
  expect_identical(transform_node$data$colors$border, "#f59e0b")
  expect_identical(target_node$data$colors$border, "#10b981")
})

test_that("create_table_node falls back to source colors for unknown types", {
  node <- create_table_node("a", "x", table_type = "not_a_type")
  expect_identical(node$data$colors$border, "#3b82f6")
})

test_that("create_column_edge builds column-to-column connections", {
  edge <- create_column_edge("customers", "id", "output", "customer_id")

  expect_identical(edge$id, "e_customers.id_to_output.customer_id")
  expect_identical(edge$source, "customers")
  expect_identical(edge$target, "output")
  expect_identical(edge$sourceHandle, "id")
  expect_identical(edge$targetHandle, "customer_id")
  expect_false(edge$animated)
  expect_null(edge$label)
})

test_that("create_column_edge adds label styling only when labelled", {
  plain <- create_column_edge("a", "x", "b", "y")
  labelled <- create_column_edge("a", "x", "b", "y", label = "SUM()", animated = TRUE)

  expect_null(plain$labelStyle)
  expect_identical(labelled$label, "SUM()")
  expect_true(labelled$animated)
  expect_false(is.null(labelled$labelStyle))
  expect_false(is.null(labelled$labelBgStyle))
})
