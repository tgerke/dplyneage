# Pure-R lineage engine: every lazy_query node class the walker handles,
# exercised on lazy_frame() fixtures — no database or Python required.

skip_if_no_r_engine <- function() {
  testthat::skip_if_not_installed("dplyr")
  testthat::skip_if_not_installed("dbplyr", "2.5.0")
}

customers_lf <- function() {
  dbplyr::lazy_frame(
    customer_id = 1L, first_name = "a", email = "a@x.com",
    .name = "customers"
  )
}

orders_lf <- function() {
  dbplyr::lazy_frame(
    order_id = 1L, customer_id = 1L, amount = 1, order_date = 1L,
    .name = "orders"
  )
}

test_that("a base table maps every column to itself", {
  skip_if_no_r_engine()

  lineage <- extract_lineage(customers_lf(), engine = "r")

  expect_edges(lineage, c(
    "customers.customer_id -> customer_id",
    "customers.first_name -> first_name",
    "customers.email -> email"
  ))
  expect_identical(node_ids(lineage), c("customers", "output"))
  expect_identical(lineage$metadata$engine, "r")
})

test_that("select and rename trace to original columns", {
  skip_if_no_r_engine()

  lineage <- customers_lf() |>
    dplyr::select(id = customer_id, contact = email) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, c(
    "customers.customer_id -> id",
    "customers.email -> contact"
  ))
})

test_that("a multi-source mutate fans in from every referenced column", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::transmute(total = amount * order_id) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, c(
    "orders.amount -> total",
    "orders.order_id -> total"
  ))
})

test_that("chained mutates resolve through intermediate columns", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::transmute(subtotal = amount + order_id) |>
    dplyr::mutate(total = subtotal * 2) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, c(
    "orders.amount -> subtotal",
    "orders.order_id -> subtotal",
    "orders.amount -> total",
    "orders.order_id -> total"
  ))
})

test_that("constant columns appear in the output node with no edges", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::transmute(order_id, flag = 1) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, "orders.order_id -> order_id")
  expect_identical(node_columns(lineage, "output"), c("flag", "order_id"))
})

test_that("filter conditions do not create lineage edges", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::filter(amount > 100) |>
    dplyr::select(order_id) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, "orders.order_id -> order_id")
})

test_that("group_by + summarise traces aggregates and group keys", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(
      total_spent = sum(amount, na.rm = TRUE),
      first_order = min(order_date, na.rm = TRUE)
    ) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, c(
    "orders.customer_id -> customer_id",
    "orders.amount -> total_spent",
    "orders.order_date -> first_order"
  ))
})

test_that("n() yields a column with no incoming edges", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(n_orders = dplyr::n()) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, "orders.customer_id -> customer_id")
  expect_identical(node_columns(lineage, "output"), c("customer_id", "n_orders"))
})

test_that("grouped (window) mutates trace like any other expression", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::group_by(customer_id) |>
    dbplyr::window_order(order_date) |>
    dplyr::transmute(running = cumsum(amount)) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, c(
    "orders.customer_id -> customer_id",
    "orders.amount -> running"
  ))
})

test_that("left joins attribute columns to the correct side", {
  skip_if_no_r_engine()

  lineage <- customers_lf() |>
    dplyr::left_join(orders_lf(), by = "customer_id") |>
    extract_lineage(engine = "r")

  expect_edges(lineage, c(
    "customers.customer_id -> customer_id",
    "customers.first_name -> first_name",
    "customers.email -> email",
    "orders.order_id -> order_id",
    "orders.amount -> amount",
    "orders.order_date -> order_date"
  ))
  expect_identical(node_ids(lineage), c("customers", "orders", "output"))
})

test_that("join suffix conflicts keep exact provenance", {
  skip_if_no_r_engine()

  a <- dbplyr::lazy_frame(id = 1L, value = 1, .name = "a")
  b <- dbplyr::lazy_frame(id = 1L, value = 2, .name = "b")

  lineage <- a |>
    dplyr::inner_join(b, by = "id") |>
    extract_lineage(engine = "r")

  expect_edges(lineage, c(
    "a.id -> id",
    "a.value -> value.x",
    "b.value -> value.y"
  ))
})

test_that("full join key columns coalesce sources from both sides", {
  skip_if_no_r_engine()

  lineage <- customers_lf() |>
    dplyr::full_join(orders_lf(), by = "customer_id") |>
    dplyr::select(customer_id, first_name, amount) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, c(
    "customers.customer_id -> customer_id",
    "orders.customer_id -> customer_id",
    "customers.first_name -> first_name",
    "orders.amount -> amount"
  ))
})

test_that("semi and anti joins contribute no columns from the filter table", {
  skip_if_no_r_engine()

  lineage <- customers_lf() |>
    dplyr::semi_join(orders_lf(), by = "customer_id") |>
    extract_lineage(engine = "r")

  expect_identical(node_ids(lineage), c("customers", "output"))
  expect_edges(lineage, c(
    "customers.customer_id -> customer_id",
    "customers.first_name -> first_name",
    "customers.email -> email"
  ))

  lineage <- customers_lf() |>
    dplyr::anti_join(orders_lf(), by = "customer_id") |>
    dplyr::select(email) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, "customers.email -> email")
})

test_that("unions merge sources from every branch", {
  skip_if_no_r_engine()

  lineage <- dplyr::union_all(
    dplyr::transmute(customers_lf(), id = customer_id),
    dplyr::transmute(orders_lf(), id = order_id)
  ) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, c(
    "customers.customer_id -> id",
    "orders.order_id -> id"
  ))
})

test_that("n-ary unions merge all branches", {
  skip_if_no_r_engine()

  c_ids <- dplyr::transmute(customers_lf(), id = customer_id)
  o_ids <- dplyr::transmute(orders_lf(), id = order_id)
  o_cust <- dplyr::transmute(orders_lf(), id = customer_id)

  lineage <- c_ids |>
    dplyr::union_all(o_ids) |>
    dplyr::union_all(o_cust) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, c(
    "customers.customer_id -> id",
    "orders.order_id -> id",
    "orders.customer_id -> id"
  ))
})

test_that("setdiff and intersect merge sources like unions", {
  skip_if_no_r_engine()

  c_ids <- dplyr::transmute(customers_lf(), id = customer_id)
  o_ids <- dplyr::transmute(orders_lf(), id = customer_id)

  lineage <- dplyr::setdiff(c_ids, o_ids) |>
    extract_lineage(engine = "r")
  expect_edges(lineage, c(
    "customers.customer_id -> id",
    "orders.customer_id -> id"
  ))

  lineage <- dplyr::intersect(c_ids, o_ids) |>
    extract_lineage(engine = "r")
  expect_edges(lineage, c(
    "customers.customer_id -> id",
    "orders.customer_id -> id"
  ))
})

test_that("distinct passes lineage through", {
  skip_if_no_r_engine()

  lineage <- customers_lf() |>
    dplyr::distinct(email) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, "customers.email -> email")
})

test_that("across() expands into per-column lineage", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::transmute(dplyr::across(c(amount, order_id), ~ .x * 2)) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, c(
    "orders.amount -> amount",
    "orders.order_id -> order_id"
  ))
})

test_that("edges are classified and labeled from their expressions", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(
      total_spent = sum(amount, na.rm = TRUE),
      n_orders = dplyr::n()
    ) |>
    extract_lineage(engine = "r")

  edges <- lineage_edges(lineage)
  agg <- edges[edges$target_column == "total_spent", ]
  expect_identical(agg$transformation, "aggregation")
  expect_identical(agg$expression, "sum(amount, na.rm = TRUE)")

  key <- edges[edges$target_column == "customer_id", ]
  expect_identical(key$transformation, "identity")

  # the widget edge carries the label and animation
  raw <- lineage$edges[[which(vapply(
    lineage$edges,
    function(e) e$targetHandle == "total_spent",
    logical(1)
  ))]]
  expect_identical(raw$label, "sum(amount, na.rm = TRUE)")
  expect_true(raw$animated)
})

test_that("renames stay identity; selecting a computed column keeps its type", {
  skip_if_no_r_engine()

  renamed <- customers_lf() |>
    dplyr::select(id = customer_id) |>
    extract_lineage(engine = "r")
  expect_identical(lineage_edges(renamed)$transformation, "identity")

  computed <- orders_lf() |>
    dplyr::transmute(subtotal = amount + order_id) |>
    dplyr::select(subtotal) |>
    extract_lineage(engine = "r")
  expect_identical(
    unique(lineage_edges(computed)$transformation),
    "transformation"
  )
})

test_that("schema-qualified tables keep their qualifier in node names", {
  skip_if_no_r_engine()

  lineage <- dbplyr::lazy_frame(
    order_id = 1L, amount = 1,
    .name = I("stg.orders")
  ) |>
    dplyr::select(order_id) |>
    extract_lineage(engine = "r")

  expect_identical(node_ids(lineage), c("output", "stg.orders"))
  expect_edges(lineage, "stg.orders.order_id -> order_id")
})

test_that("a table named 'output' does not collide with the output node", {
  skip_if_no_r_engine()

  lineage <- dbplyr::lazy_frame(x = 1, .name = "output") |>
    extract_lineage(engine = "r")

  expect_identical(node_ids(lineage), c("output", "output_"))
  expect_edges(lineage, "output.x -> x")
})

test_that("raw SQL expressions raise a classed error under engine = 'r'", {
  skip_if_no_r_engine()

  query <- orders_lf() |>
    dplyr::mutate(bumped = dbplyr::sql("amount + 1"))

  expect_error(
    extract_lineage(query, engine = "r"),
    class = "dplyneage_unsupported_lineage"
  )
})

test_that("engine = 'r' rejects SQL strings", {
  expect_error(
    extract_lineage("SELECT 1", engine = "r"),
    "only works with dbplyr lazy tables"
  )
})

test_that("auto engine errors clearly when unsupported and sqlglot is absent", {
  skip_if_no_r_engine()

  query <- orders_lf() |>
    dplyr::mutate(bumped = dbplyr::sql("amount + 1"))

  local_mocked_bindings(has_sqlglot = function() FALSE)
  expect_error(
    extract_lineage(query, engine = "auto"),
    "sqlglot is not available"
  )
})

# Indirect lineage (include_indirect = TRUE) ---------------------------

test_that("include_indirect adds dashed filter edges to every output column", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::filter(amount > 100) |>
    dplyr::select(order_id, customer_id) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  edges <- lineage_edges(lineage)
  filters <- edges[edges$transformation == "filter", ]
  expect_identical(filters$source_column, c("amount", "amount"))
  expect_identical(sort(filters$target_column), c("customer_id", "order_id"))
  expect_true(all(is.na(filters$expression)))

  # The filter column joins its table's node, and the edge draws dashed
  expect_identical(
    node_columns(lineage, "orders"),
    c("amount", "customer_id", "order_id")
  )
  dashed <- Filter(function(e) !is.null(e$style$strokeDasharray), lineage$edges)
  expect_length(dashed, 2L)
})

test_that("indirect edges are off by default", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::filter(amount > 100) |>
    dplyr::select(order_id) |>
    extract_lineage(engine = "r")

  expect_edges(lineage, "orders.order_id -> order_id")
  expect_false("amount" %in% node_columns(lineage, "orders"))
})

test_that("a direct edge suppresses the duplicate indirect edge", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::filter(amount > 100) |>
    dplyr::transmute(amount) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  edges <- lineage_edges(lineage)
  expect_identical(nrow(edges), 1L)
  expect_identical(edges$transformation, "identity")
})

test_that("group keys and sort columns are classified by use", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total_spent = sum(amount, na.rm = TRUE)) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  edges <- lineage_edges(lineage)
  group_by <- edges[edges$transformation == "group_by", ]
  # customer_id -> customer_id is already an identity edge; only the
  # aggregate column gains the indirect group_by edge
  expect_identical(group_by$source_column, "customer_id")
  expect_identical(group_by$target_column, "total_spent")

  sorted <- orders_lf() |>
    dplyr::arrange(dplyr::desc(order_date)) |>
    dplyr::select(order_id) |>
    extract_lineage(engine = "r", include_indirect = TRUE)
  sort_edges <- lineage_edges(sorted)
  expect_identical(
    sort_edges[sort_edges$transformation == "sort", ]$source_column,
    "order_date"
  )
})

test_that("join keys on both sides become indirect join edges", {
  skip_if_no_r_engine()

  lineage <- customers_lf() |>
    dplyr::left_join(orders_lf(), by = "customer_id") |>
    dplyr::transmute(first_name, amount) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  edges <- lineage_edges(lineage)
  joins <- edges[edges$transformation == "join", ]
  expect_identical(
    sort(unique(paste0(joins$source_table, ".", joins$source_column))),
    c("customers.customer_id", "orders.customer_id")
  )
})

test_that("semi join match columns from the filter table appear indirectly", {
  skip_if_no_r_engine()

  lineage <- customers_lf() |>
    dplyr::semi_join(orders_lf(), by = "customer_id") |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  edges <- lineage_edges(lineage)
  joins <- edges[edges$transformation == "join", ]
  expect_in("orders.customer_id", paste0(joins$source_table, ".", joins$source_column))
  expect_in("orders", node_ids(lineage))
})

test_that("filters after summarise resolve through the aggregate", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total_spent = sum(amount, na.rm = TRUE)) |>
    dplyr::filter(total_spent > 500) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  edges <- lineage_edges(lineage)
  filters <- edges[edges$transformation == "filter", ]
  # total_spent's own sources (orders.amount) carry the filter, resolved
  # through the intermediate aggregate
  expect_identical(
    sort(unique(filters$source_column)),
    "amount"
  )
})
