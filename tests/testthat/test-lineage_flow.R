test_that("lineage_flow returns an htmlwidget with nodes and edges", {
  nodes <- list(
    list(id = "1", position = list(x = 0, y = 0), data = list(label = "a")),
    list(id = "2", position = list(x = 100, y = 0), data = list(label = "b"))
  )
  edges <- list(list(id = "e1", source = "1", target = "2"))

  w <- lineage_flow(nodes, edges)

  expect_s3_class(w, "htmlwidget")
  expect_s3_class(w, "lineage_flow")
  expect_identical(w$x$nodes, nodes)
  expect_identical(w$x$edges, edges)
})

test_that("lineage_flow auto-detects an extract_lineage() result", {
  lineage <- list(
    nodes = list(list(id = "t", position = list(x = 0, y = 0), data = list(label = "t"))),
    edges = list(list(id = "e", source = "t", target = "t")),
    metadata = list(sql = "SELECT 1")
  )

  w <- lineage_flow(lineage)

  expect_identical(w$x$nodes, lineage$nodes)
  expect_identical(w$x$edges, lineage$edges)
})

test_that("lineage_flow applies default dimensions", {
  w <- lineage_flow(list(), list())
  expect_identical(w$width, "100%")
  expect_identical(w$height, "600px")

  w2 <- lineage_flow(list(), list(), width = "50%", height = "300px")
  expect_identical(w2$width, "50%")
  expect_identical(w2$height, "300px")
})

test_that("widget options ride the payload", {
  w <- lineage_flow(list(), list())
  expect_identical(
    w$x$options,
    list(minimap = FALSE, legend = TRUE, theme = "light", exportButton = TRUE)
  )

  w <- lineage_flow(
    list(), list(),
    minimap = TRUE, legend = FALSE, theme = "dark", export_button = FALSE
  )
  expect_identical(
    w$x$options,
    list(minimap = TRUE, legend = FALSE, theme = "dark", exportButton = FALSE)
  )

  expect_error(lineage_flow(list(), list(), theme = "sepia"), "arg")
})

test_that("lineage_example builds a widget without Python", {
  w <- lineage_example()
  expect_s3_class(w, "htmlwidget")
  expect_length(w$x$nodes, 3)
  expect_length(w$x$edges, 5)
})

test_that("column labels ride the widget payload", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  df <- data.frame(amount = 1)
  attr(df$amount, "label") <- "Order amount"

  w <- dbplyr::tbl_lazy(df, name = "orders") |>
    dplyr::mutate(doubled = amount * 2) |>
    extract_lineage(engine = "r") |>
    lineage_flow()

  orders <- Filter(function(n) n$id == "orders", w$x$nodes)[[1]]
  expect_identical(orders$data$columnLabels, list(amount = "Order amount"))
})
