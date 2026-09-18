# Screen-space distance, in px, between each end of every edge and the handle
# it should touch. Edges leave the right edge of the source handle and arrive
# at the left edge of the target handle, both at mid height.
edge_offsets <- function(page) {
  edges <- lapply(page$x$edges, function(e) {
    e[c("id", "source", "sourceHandle", "target", "targetHandle")]
  })
  js(page, sprintf("(function(edges) { return edges.map(function(e) {
    var s = __t.handle(e.source, e.sourceHandle, 'source').getBoundingClientRect();
    var t = __t.handle(e.target, e.targetHandle, 'target').getBoundingClientRect();
    var a = __t.pointOn(e.id, 0);
    var b = __t.pointOn(e.id, 1);
    return {
      id: e.id,
      source: Math.hypot(a.x - s.right, a.y - (s.top + s.height / 2)),
      target: Math.hypot(b.x - t.left, b.y - (t.top + t.height / 2))
    };
  }); })(%s)", q(edges)))
}

# Measured offsets are 0.000px with a correct bundle. Without the
# @xyflow/system patch they run from 50px to over 300px under an ancestor
# scale, so 1px separates the two cleanly.
expect_edges_on_handles <- function(page) {
  offsets <- edge_offsets(page)
  expect_length(offsets, length(page$x$edges))
  for (offset in offsets) {
    expect_lt(offset$source, 1, label = paste("source end of", offset$id, "(px off its handle)"))
    expect_lt(offset$target, 1, label = paste("target end of", offset$id, "(px off its handle)"))
  }
}

scaled <- function(factor) {
  function(widget) {
    htmltools::div(
      style = sprintf("transform: scale(%s); transform-origin: 0 0; width: 1400px;", factor),
      widget
    )
  }
}

test_that("edges meet their handles", {
  expect_edges_on_handles(local_widget_page(lineage_example()))
  expect_edges_on_handles(local_widget_page(rich_widget()))
})

# Regression test for srcjs/patches/@xyflow+system+0.0.74.patch: a reveal.js
# slide or zoomed iframe scales the widget from outside, which React Flow's
# handle measurement does not account for on its own
test_that("edges meet their handles under an ancestor CSS scale", {
  expect_edges_on_handles(local_widget_page(lineage_example(), wrap = scaled(0.6)))
  expect_edges_on_handles(local_widget_page(rich_widget(), wrap = scaled(1.5)))
})

test_that("edges stay on their handles through zooming", {
  page <- local_widget_page(lineage_example())
  before <- js(page, "__t.zoom()")
  mouse_click(page, js(page, "__t.center(__t.button('Zoom Out'))"))
  wait_for(page, sprintf("__t.zoom() < %s", before))
  wait_stable(page, "document.querySelector('.react-flow__viewport').style.transform")
  expect_edges_on_handles(page)
})

test_that("a dragged node takes its edges with it", {
  page <- local_widget_page(lineage_example())
  header <- js(page, "__t.center(__t.card('orders').firstElementChild)")
  before <- js(page, "__t.node('orders').style.transform")

  mouse_drag(page, header, list(x = header$x - 120, y = header$y + 60))

  wait_for(page, sprintf("__t.node('orders').style.transform !== %s", q(before)))
  wait_stable(page, "__t.node('orders').style.transform")
  expect_edges_on_handles(page)
})
