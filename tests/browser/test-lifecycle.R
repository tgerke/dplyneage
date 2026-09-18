viewport_transform <- "document.querySelector('.react-flow__viewport').style.transform"

test_that("rendering a new value replaces the old graph instead of stacking on it", {
  page <- local_widget_page(lineage_example())
  replacement <- rich_widget()$x

  # Shiny re-renders arrive the same way: renderValue() on the live instance
  js(page, sprintf("__t.widget().renderValue(%s); true", q(replacement)))

  wait_for_flow(page, length(replacement$nodes), length(replacement$edges))
  expect_equal(js(page, "__t.all('.react-flow').length"), 1)
  expect_setequal(
    unlist(js(page, "__t.all('.react-flow__node').map(function(n) { return n.dataset.id; })")),
    vapply(replacement$nodes, function(n) n$id, "")
  )
  expect_identical(unlist(js(page, "__t.legend()")), c("Source", "Target", "Direct", "Indirect"))
  expect_identical(page$problems$seen, character())
})

# React Flow mounted at zero size pins the viewport at minZoom (0.1), where
# later fits no-op, so the widget waits for real dimensions first
test_that("a widget in a hidden container renders once it is revealed, fitted", {
  page <- local_widget_page(
    lineage_example(),
    wrap = function(widget) htmltools::div(id = "hider", style = "display: none;", widget),
    ready = FALSE
  )
  expect_equal(js(page, "__t.all('.react-flow').length"), 0)

  js(page, "document.getElementById('hider').style.display = 'block'; true")

  wait_for_flow(page)
  expect_gt(js(page, "__t.zoom()"), 0.5)
  expect_identical(page$problems$seen, character())
})

test_that("the graph re-fits when its container changes size", {
  page <- local_widget_page(lineage_example())
  before <- js(page, viewport_transform)

  js(page, "document.querySelector('.lineage_flow').style.width = '700px'; true")

  expect_eventually(page, sprintf("%s !== %s", viewport_transform, q(before)))
  narrow <- wait_stable(page, viewport_transform)

  # htmlwidgets' own resize hook fits too
  js(page, "document.querySelector('.lineage_flow').style.width = '1200px'; __t.widget().resize(1200, 600); true")
  expect_eventually(page, sprintf("%s !== %s", viewport_transform, q(narrow)))
})

test_that("without the React Flow bundle the widget degrades to the static SVG", {
  page <- local_widget_page(
    lineage_example(),
    # Swallow the bundle's global so the binding finds none
    before_load = "Object.defineProperty(window, 'ReactFlowBundle', {
      get: function() { return undefined; },
      set: function() {}
    });",
    ready = FALSE
  )
  wait_for(page, "document.querySelector('.lineage_flow svg') !== null")
  expect_true(js(page, "document.body.innerText.includes('Column lineage (static SVG) | Tables: 3 | Edges: 5')"))
  expect_equal(js(page, "__t.all('.react-flow').length"), 0)
})
