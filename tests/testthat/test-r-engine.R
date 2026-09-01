# Pure-R lineage engine: every lazy_query node class the walker handles,
# exercised on lazy_frame() fixtures — no database or Python required.

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

test_that("window partition and ordering columns are direct sources", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::group_by(customer_id) |>
    dbplyr::window_order(order_date) |>
    dplyr::transmute(running = cumsum(amount)) |>
    extract_lineage(engine = "r")

  # cumsum renders OVER (PARTITION BY customer_id ORDER BY order_date),
  # so both clause columns feed `running` alongside amount, exactly as
  # the sqlglot engine reads them out of the rendered SQL
  expect_edges(lineage, c(
    "orders.customer_id -> customer_id",
    "orders.amount -> running",
    "orders.customer_id -> running",
    "orders.order_date -> running"
  ))
})

test_that("windows classify by function and desc() ordering resolves", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::group_by(customer_id) |>
    dbplyr::window_order(dplyr::desc(order_date)) |>
    dplyr::transmute(
      rn = dplyr::row_number(),
      total = sum(amount, na.rm = TRUE)
    ) |>
    extract_lineage(engine = "r")

  edges <- lineage_edges(lineage)
  rn <- edges[edges$target_column == "rn", ]
  expect_setequal(rn$source_column, c("customer_id", "order_date"))
  expect_identical(unique(rn$transformation), "transformation")

  # a plain aggregate windows without ORDER BY: no order_date source
  total <- edges[edges$target_column == "total", ]
  expect_setequal(total$source_column, c("amount", "customer_id"))
  expect_identical(unique(total$transformation), "aggregation")
})

test_that("grouped mutates without window functions gain no sources", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::group_by(customer_id) |>
    dplyr::mutate(bumped = amount + 1) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  edges <- lineage_edges(lineage)
  bumped <- edges[edges$target_column == "bumped", ]
  expect_identical(bumped$source_column, "amount")
  expect_false(any(edges$transformation %in% c("sort", "group_by")))
})

test_that("explicit ordering arguments override window_order()", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::group_by(customer_id) |>
    dbplyr::window_order(order_date) |>
    dplyr::transmute(prev = dplyr::lag(amount, order_by = order_id)) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  edges <- lineage_edges(lineage)
  prev <- edges[edges$target_column == "prev" & edges$transformation != "sort", ]
  expect_setequal(prev$source_column, c("amount", "order_id", "customer_id"))
  expect_false("order_date" %in% edges$source_column)
  expect_setequal(
    edges[edges$transformation == "sort", ]$source_column,
    "order_id"
  )
})

test_that("window ordering emits indirect sort edges with fan-out", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::group_by(customer_id) |>
    dbplyr::window_order(order_date) |>
    dplyr::transmute(
      rn = dplyr::row_number(),
      total = sum(amount, na.rm = TRUE)
    ) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  edges <- lineage_edges(lineage)
  sort_edges <- edges[edges$transformation == "sort", ]
  # order_date -> rn is already direct, so the indirect fan-out reaches
  # only the other outputs
  expect_setequal(
    paste0(sort_edges$source_column, "->", sort_edges$target_column),
    c("order_date->customer_id", "order_date->total")
  )
})

test_that("rank functions with an argument order by the argument", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::transmute(rnk = dplyr::min_rank(amount)) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  edges <- lineage_edges(lineage)
  rnk <- edges[edges$target_column == "rnk" & edges$transformation != "sort", ]
  expect_identical(rnk$source_column, "amount")
  # OVER (ORDER BY amount) with no partition; transmute keeps only rnk
  # and amount -> rnk is direct, so no indirect edge survives dedupe
  expect_false(any(edges$transformation == "sort"))
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
    "walks a lazy query tree"
  )
})

test_that("select expressions normalize across dbplyr storage styles", {
  skip_if_no_r_engine()
  testthat::skip_if_not_installed("rlang")

  # dbplyr 2.5.x stores computed expressions as quosures; 2.6.0 stores
  # them bare — strip_quosure() must accept both
  q <- rlang::new_quosure(quote(sum(amount, na.rm = TRUE)), emptyenv())
  expect_identical(strip_quosure(q), quote(sum(amount, na.rm = TRUE)))
  expect_identical(strip_quosure(quote(amount)), quote(amount))

  # raw SQL in every stored representation: evaluated sql object
  # (dbplyr >= 2.6 or !!-injected), bare or namespaced sql() call (2.5.x)
  expect_true(uses_raw_sql(dbplyr::sql("amount + 1")))
  expect_true(uses_raw_sql(quote(sql("amount + 1"))))
  expect_true(uses_raw_sql(quote(dbplyr::sql("amount + 1"))))

  # a column merely named sql is not raw SQL
  expect_false(uses_raw_sql(quote(sql + 1)))
  expect_false(uses_raw_sql(quote(sum(amount, na.rm = TRUE))))
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
  # summarise rows carry no window state: GROUP BY aggregates must not
  # pick up window partition or ordering sources
  expect_false(any(edges$transformation == "sort"))

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

test_that("raw SQL in filter/arrange falls back only under include_indirect", {
  skip_if_no_r_engine()

  filtered <- orders_lf() |>
    dplyr::filter(dbplyr::sql("amount > 10"))

  # Without indirect collection the clause cannot affect the result, so
  # the R engine still traces
  lineage <- extract_lineage(filtered, engine = "r")
  expect_identical(lineage$metadata$engine, "r")

  # With it, silently dropping the clause would lose edges: signal the
  # classed condition so engine = "auto" can fall back to sqlglot
  expect_error(
    extract_lineage(filtered, engine = "r", include_indirect = TRUE),
    class = "dplyneage_unsupported_lineage"
  )
  expect_error(
    orders_lf() |>
      dplyr::arrange(dbplyr::sql("amount DESC")) |>
      extract_lineage(engine = "r", include_indirect = TRUE),
    class = "dplyneage_unsupported_lineage"
  )
})

test_that("dialect is inferred from the connection when NULL", {
  skip_if_no_r_engine()

  lf <- dbplyr::lazy_frame(x = 1, .name = "t", con = dbplyr::simulate_postgres())
  expect_identical(extract_lineage(lf)$metadata$dialect, "postgres")
  expect_identical(
    extract_lineage(lf, dialect = "mysql")$metadata$dialect,
    "mysql"
  )
  # Unrecognized connections (lazy_frame's simulate_dbi) keep the
  # historical default
  expect_identical(extract_lineage(customers_lf())$metadata$dialect, "duckdb")
})

test_that("infer_dialect maps driver classes and falls back to duckdb", {
  fake <- function(cls) structure(list(), class = c(cls, "DBIConnection"))
  expect_identical(infer_dialect(fake("PqConnection")), "postgres")
  expect_identical(infer_dialect(fake("Snowflake")), "snowflake")
  expect_identical(infer_dialect(fake("Microsoft SQL Server")), "tsql")
  expect_identical(infer_dialect(fake("SomethingElse")), "duckdb")
})

test_that("tbl_lazy frames trace without any database", {
  skip_if_no_r_engine()

  lineage <- dbplyr::tbl_lazy(
    data.frame(customer_id = 1, amount = 10),
    name = "sales"
  ) |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE)) |>
    extract_lineage()

  expect_edges(lineage, c(
    "sales.customer_id -> customer_id",
    "sales.amount -> total"
  ))
  expect_identical(lineage$metadata$engine, "r")
})

test_that("rewriting an aggregate surfaces as a changed edge in lineage_diff", {
  skip_if_no_r_engine()

  old <- orders_lf() |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE)) |>
    extract_lineage()
  new <- orders_lf() |>
    dplyr::summarise(total = mean(amount, na.rm = TRUE)) |>
    extract_lineage()

  diff <- lineage_diff(old, new)
  expect_identical(nrow(diff$changed_edges), 1L)
  expect_identical(diff$changed_edges$old_expression, "sum(amount, na.rm = TRUE)")
  expect_identical(diff$changed_edges$new_expression, "mean(amount, na.rm = TRUE)")
  expect_true(lineage_has_changes(diff))
})

test_that("a column filtered and sorted on keeps one edge with both kinds", {
  skip_if_no_r_engine()

  lineage <- orders_lf() |>
    dplyr::filter(amount > 10) |>
    dbplyr::window_order(amount) |>
    dplyr::transmute(customer_id, rn = dplyr::row_number()) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  edge <- Filter(
    function(e) e$sourceHandle == "amount" && e$targetHandle == "customer_id",
    lineage$edges
  )
  expect_length(edge, 1L)
  expect_setequal(edge[[1]]$data$transformations, c("filter", "sort"))
  expect_identical(
    edge[[1]]$data$transformation,
    edge[[1]]$data$transformations[[1]]
  )

  # The edges frame shows the first kind; amount -> rn stays direct
  edges <- lineage_edges(lineage)
  pair <- edges[
    edges$source_column == "amount" & edges$target_column == "customer_id",
  ]
  expect_identical(nrow(pair), 1L)
  expect_identical(pair$transformation, edge[[1]]$data$transformation)
})

test_that("label attributes on a local frame become column labels", {
  skip_if_no_r_engine()

  df <- data.frame(customer_id = 1L, amount = 2.5)
  attr(df$amount, "label") <- "Order amount in USD"

  lineage <- dbplyr::tbl_lazy(df, name = "orders") |>
    dplyr::select(customer_id, amount) |>
    extract_lineage(engine = "r")

  orders <- Filter(function(n) n$id == "orders", lineage$nodes)[[1]]
  expect_identical(
    orders$data$columnLabels,
    list(amount = "Order amount in USD")
  )
})

test_that("the labels argument supplies labels and beats attributes", {
  skip_if_no_r_engine()

  df <- data.frame(customer_id = 1L, amount = 2.5)
  attr(df$amount, "label") <- "From the attribute"

  lineage <- dbplyr::tbl_lazy(df, name = "orders") |>
    dplyr::select(customer_id, amount) |>
    extract_lineage(
      engine = "r",
      labels = list(orders = c(
        amount = "From the argument",
        customer_id = "Customer id"
      ))
    )

  orders <- Filter(function(n) n$id == "orders", lineage$nodes)[[1]]
  expect_identical(orders$data$columnLabels$amount, "From the argument")
  expect_identical(orders$data$columnLabels$customer_id, "Customer id")
})

test_that("a malformed labels argument errors with the expected shape", {
  skip_if_no_r_engine()

  expect_error(
    extract_lineage(customers_lf(), engine = "r", labels = list("plain")),
    "named list mapping tables"
  )
  expect_error(
    extract_lineage(
      customers_lf(),
      engine = "r",
      labels = list(customers = "unnamed label")
    ),
    "named list mapping tables"
  )
})

test_that("semi-join filter sides stay unwalked without include_indirect", {
  skip_if_no_r_engine()

  # The y side uses raw SQL, which the walker refuses only while
  # indirect collection is active; the always-present collector env must
  # not change that
  flagged <- orders_lf() |>
    dplyr::filter(dbplyr::sql("amount > 10"))
  lineage <- customers_lf() |>
    dplyr::semi_join(flagged, by = "customer_id") |>
    extract_lineage(engine = "r")

  expect_edges(lineage, c(
    "customers.customer_id -> customer_id",
    "customers.first_name -> first_name",
    "customers.email -> email"
  ))
})

test_that("types and labels propagate along identity edges only", {
  skip_if_no_r_engine()

  lineage <- dbplyr::lazy_frame(customer_id = 1L, amount = 1, .name = "orders") |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE)) |>
    extract_lineage(
      engine = "r",
      schema = list(orders = list(customer_id = "INTEGER", amount = "DOUBLE")),
      labels = list(orders = c(customer_id = "Customer id", amount = "Amount"))
    )

  output <- Filter(function(n) n$id == "output", lineage$nodes)[[1]]
  expect_identical(output$data$columnTypes, list(customer_id = "INTEGER"))
  expect_identical(output$data$columnLabels, list(customer_id = "Customer id"))
})

test_that("conflicting identity sources propagate nothing", {
  skip_if_no_r_engine()

  lineage <- dbplyr::lazy_frame(a = 1L, .name = "t1") |>
    dplyr::union_all(dbplyr::lazy_frame(a = "x", .name = "t2")) |>
    extract_lineage(
      engine = "r",
      schema = list(t1 = list(a = "INTEGER"), t2 = list(a = "TEXT")),
      labels = list(t1 = c(a = "Same label"), t2 = c(a = "Same label"))
    )

  output <- Filter(function(n) n$id == "output", lineage$nodes)[[1]]
  # Disagreeing types stay off the union column — missing beats wrong —
  # while the label both branches agree on flows through
  expect_null(output$data$columnTypes)
  expect_identical(output$data$columnLabels, list(a = "Same label"))
})

# --- mutate family ----------------------------------------------------

test_that("mutate-family shapes match the shared expectations", {
  skip_if_no_r_engine()

  run_mutate_shapes(
    engine = "dbplyr",
    input = function(df) dbplyr::tbl_lazy(df, name = "df"),
    extract = function(x, ii) {
      extract_lineage(x, engine = "r", include_indirect = ii)
    }
  )
})
