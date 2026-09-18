test_that("the example graph mounts through React Flow with every node and edge", {
  page <- local_widget_page(lineage_example())
  node_ids <- vapply(page$x$nodes, function(n) n$id, "")
  edge_ids <- vapply(page$x$edges, function(e) e$id, "")

  expect_setequal(unlist(js(page, "__t.all('.react-flow__node').map(function(n) { return n.dataset.id; })")), node_ids)
  expect_setequal(unlist(js(page, "__t.all('.react-flow__edge').map(function(g) { return g.dataset.id; })")), edge_ids)
  expect_false(js(page, "document.body.innerText.includes('static SVG')"))
  expect_identical(page$problems$seen, character())
})

test_that("each node shows its label and one row of handles per column", {
  page <- local_widget_page(lineage_example())
  for (node in page$x$nodes) {
    card <- sprintf("__t.card(%s)", q(node$id))
    expect_identical(js(page, paste0(card, ".firstElementChild.innerText")), node$data$label)
    rows <- unlist(js(page, paste0(
      "Array.prototype.map.call(", card, ".lastElementChild.children, function(r) { return r.innerText; })"
    )))
    expect_identical(rows, unlist(node$data$columns))
    expect_equal(
      js(page, paste0(card, ".querySelectorAll('.react-flow__handle.source').length")),
      length(node$data$columns)
    )
    expect_equal(
      js(page, paste0(card, ".querySelectorAll('.react-flow__handle.target').length")),
      length(node$data$columns)
    )
  }
})

test_that("edge labels render once per labelled edge", {
  page <- local_widget_page(lineage_example())
  labels <- unlist(lapply(page$x$edges, function(e) e$label))
  expect_gt(length(labels), 0)
  expect_setequal(
    unlist(js(page, "__t.all('.react-flow__edgelabel-renderer > div').map(function(d) { return d.innerText; })")),
    labels
  )
})

test_that("the legend names the node types and edge kinds in the graph", {
  page <- local_widget_page(lineage_example())
  expect_identical(unlist(js(page, "__t.legend()")), c("Source", "Target", "Direct"))

  page <- local_widget_page(rich_widget())
  expect_identical(unlist(js(page, "__t.legend()")), c("Source", "Target", "Direct", "Indirect"))
})

test_that("indirect edges keep their dashes in the DOM", {
  page <- local_widget_page(rich_widget())
  for (edge in page$x$edges) {
    dash <- js(page, sprintf("getComputedStyle(__t.path(%s)).strokeDasharray", q(edge$id)))
    if (is.null(edge$style$strokeDasharray)) {
      expect_identical(dash, "none")
    } else {
      expect_identical(dash, "6px, 4px")
    }
  }
})

test_that("legend, minimap, and export button follow their options", {
  page <- local_widget_page(lineage_example())
  expect_false(is.null(js(page, "__t.legend()")))
  expect_equal(js(page, "__t.all('.react-flow__minimap').length"), 0)
  expect_equal(js(page, "__t.all('.react-flow__controls button[title=\"Download PNG\"]').length"), 1)

  example <- lineage_example()$x
  page <- local_widget_page(
    lineage_flow(example$nodes, example$edges, legend = FALSE, minimap = TRUE, export_button = FALSE)
  )
  expect_null(js(page, "__t.legend()"))
  expect_equal(js(page, "__t.all('.react-flow__minimap').length"), 1)
  expect_equal(js(page, "__t.all('.react-flow__controls button[title=\"Download PNG\"]').length"), 0)
})
