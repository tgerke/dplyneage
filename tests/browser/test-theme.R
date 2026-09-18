dark_node_bg <- "rgb(30, 30, 30)"
light_gray <- "rgb(148, 163, 184)"

emulate_scheme <- function(b, scheme) {
  b$Emulation$setEmulatedMedia(
    features = list(list(name = "prefers-color-scheme", value = scheme))
  )
}

test_that("the dark theme recolors React Flow, the nodes, and the default edge gray", {
  page <- local_widget_page(rich_widget(theme = "dark"))
  direct <- Filter(function(e) is.null(e$style$strokeDasharray), page$x$edges)[[1]]

  expect_true(js(page, "document.querySelector('.react-flow').classList.contains('dark')"))
  expect_identical(js(page, "getComputedStyle(__t.card('orders')).backgroundColor"), dark_node_bg)
  # R sends #64748b; on a dark canvas the two grays swap roles
  expect_identical(direct$style$stroke, "#64748b")
  expect_identical(js(page, sprintf("__t.path(%s).style.stroke", q(direct$id))), light_gray)
})

test_that("an explicit light theme ignores a dark system preference", {
  page <- local_widget_page(
    lineage_example(),
    setup = function(b) emulate_scheme(b, "dark")
  )
  expect_true(js(page, "document.querySelector('.react-flow').classList.contains('light')"))
})

test_that("theme = 'auto' follows prefers-color-scheme while the page is open", {
  example <- lineage_example()$x
  page <- local_widget_page(
    lineage_flow(example$nodes, example$edges, theme = "auto"),
    setup = function(b) emulate_scheme(b, "light")
  )
  expect_true(js(page, "document.querySelector('.react-flow').classList.contains('light')"))

  emulate_scheme(page$b, "dark")
  expect_eventually(page, "document.querySelector('.react-flow').classList.contains('dark')")
  expect_eventually(page, sprintf(
    "getComputedStyle(__t.card('orders')).backgroundColor === %s", q(dark_node_bg)
  ))

  emulate_scheme(page$b, "light")
  expect_eventually(page, "document.querySelector('.react-flow').classList.contains('light')")
})
