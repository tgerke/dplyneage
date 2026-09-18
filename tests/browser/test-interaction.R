amber <- "rgb(245, 158, 11)"
selected_row <- "rgb(254, 243, 199)"

edge_id <- function(x, source, source_handle, target_handle = NULL) {
  hits <- Filter(function(e) {
    e$source == source && e$sourceHandle == source_handle &&
      (is.null(target_handle) || e$targetHandle == target_handle)
  }, x$edges)
  vapply(hits, function(e) e$id, "")
}

pane_corner <- function(page) {
  js(page, "(function() {
    var r = document.querySelector('.react-flow__pane').getBoundingClientRect();
    return { x: r.left + 15, y: r.top + 15 };
  })()")
}

# Checks for the cone's own 0.15: after a release by click or Escape the
# pointer still rests on the row, so hover dimming (0.3) rightly remains
expect_cone_released <- function(page) {
  expect_eventually(page, "__t.all('.react-flow__node').every(function(n) {
    return n.firstElementChild.style.opacity === '1';
  })")
  expect_eventually(page, "__t.all('.react-flow__edge-path').every(function(p) {
    return p.style.opacity !== '0.15';
  })")
}

test_that("clicking a column isolates its cone", {
  page <- local_widget_page(lineage_example())
  traced <- edge_id(page$x, "orders", "order_date")
  expect_length(traced, 1)

  click_column(page, "orders", "order_date")

  expect_eventually(page, sprintf(
    "getComputedStyle(__t.row('orders', 'order_date')).backgroundColor === %s", q(selected_row)
  ))
  # customers has no column in the cone, so the whole node dims
  expect_eventually(page, "__t.card('customers').style.opacity === '0.3'")
  expect_identical(js(page, "__t.card('orders').style.opacity"), "1")
  expect_identical(js(page, "__t.card('customer_summary').style.opacity"), "1")
  # rows outside the cone dim on the nodes that stay lit
  expect_identical(js(page, "__t.row('orders', 'order_id').style.opacity"), "0.35")
  expect_identical(js(page, "__t.row('customer_summary', 'email').style.opacity"), "0.35")
  expect_identical(js(page, "__t.row('customer_summary', 'first_order').style.opacity"), "1")

  for (edge in page$x$edges) {
    opacity <- js(page, sprintf("__t.path(%s).style.opacity", q(edge$id)))
    expect_identical(opacity, if (edge$id %in% traced) "" else "0.15", label = edge$id)
  }
})

test_that("a second click, Escape, and a pane click each release the cone", {
  page <- local_widget_page(lineage_example())
  dimmed <- "__t.card('customers').style.opacity === '0.3'"

  click_column(page, "orders", "order_date")
  expect_eventually(page, dimmed)
  click_column(page, "orders", "order_date")
  expect_cone_released(page)

  click_column(page, "orders", "order_date")
  expect_eventually(page, dimmed)
  press_escape(page)
  expect_cone_released(page)

  click_column(page, "orders", "order_date")
  expect_eventually(page, dimmed)
  mouse_click(page, pane_corner(page))
  expect_cone_released(page)
})

test_that("hovering a column highlights its edges and dims the rest", {
  page <- local_widget_page(rich_widget())
  lit <- edge_id(page$x, "orders", "amount")
  other <- edge_id(page$x, "orders", "id")

  hover_column(page, "orders", "amount")

  expect_eventually(page, sprintf("__t.path(%s).style.stroke === %s", q(lit), q(amber)))
  expect_identical(js(page, sprintf("__t.path(%s).style.strokeWidth", q(lit))), "3")
  expect_true(js(page, sprintf("__t.edge(%s).classList.contains('animated')", q(lit))))
  expect_identical(js(page, sprintf("__t.path(%s).style.opacity", q(other))), "0.3")

  mouse_move(page, pane_corner(page))
  expect_eventually(page, sprintf("__t.path(%s).style.strokeWidth === '2'", q(lit)))
  expect_identical(js(page, sprintf("__t.path(%s).style.opacity", q(other))), "")
})

test_that("the column card shows type and label, and only where metadata exists", {
  widget <- rich_widget()
  orders <- which(vapply(widget$x$nodes, function(n) n$id, "") == "orders")
  widget$x$nodes[[orders]]$data$columnTypes <- list(amount = "DOUBLE")
  page <- local_widget_page(widget)

  hover_column(page, "orders", "amount")
  expect_eventually(page, "__t.hoverCard() !== null")
  expect_identical(
    strsplit(js(page, "__t.hoverCard()"), "\n")[[1]],
    c("amount", "DOUBLE", "Order amount")
  )

  # id carries no type or label: its edge lights up but no card appears
  hover_column(page, "orders", "id")
  expect_eventually(page, sprintf(
    "__t.path(%s).style.stroke === %s", q(edge_id(page$x, "orders", "id")), q(amber)
  ))
  expect_null(js(page, "__t.hoverCard()"))
})

test_that("the edge card names the kind and, for direct edges, the expression", {
  page <- local_widget_page(rich_widget())
  direct <- edge_id(page$x, "orders", "amount")
  indirect <- edge_id(page$x, "orders", "region", "id")

  # Close to the source, where no other edge shares the line
  mouse_move(page, js(page, sprintf("__t.pointOn(%s, 0.05)", q(direct))))
  expect_eventually(page, "__t.hoverCard() !== null")
  expect_identical(
    tolower(strsplit(js(page, "__t.hoverCard()"), "\n")[[1]]),
    c("transformation", "amount * 2")
  )

  mouse_move(page, pane_corner(page))
  expect_eventually(page, "__t.hoverCard() === null")

  mouse_move(page, js(page, sprintf("__t.pointOn(%s, 0.05)", q(indirect))))
  expect_eventually(page, "__t.hoverCard() !== null")
  expect_identical(tolower(js(page, "__t.hoverCard()")), "filter")
})

test_that("the traced column is reported to Shiny as <id>_selected", {
  page <- local_widget_page(
    lineage_example(),
    before_load = "
      window.__shiny = [];
      window.Shiny = { setInputValue: function(name, value) { window.__shiny.push([name, value]); } };
    "
  )
  input <- paste0(js(page, "document.querySelector('.lineage_flow').id"), "_selected")
  last <- "window.__shiny[window.__shiny.length - 1]"

  # published as null on mount so the input always exists
  expect_identical(js(page, last), list(input, NULL))

  click_column(page, "orders", "order_date")
  expect_eventually(page, paste0(last, "[1] !== null"))
  expect_identical(js(page, last), list(input, list(table = "orders", column = "order_date")))

  press_escape(page)
  expect_eventually(page, paste0(last, "[1] === null"))
  expect_identical(page$problems$seen, character())
})
