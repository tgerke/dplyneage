# The dtplyr engine walks lazy_dt() step trees. Expressions arrive
# data.table-translated (n() is .N, case_when() is fcase(), row_number()
# is seq_len(.N)), so several cases here pin the classifier against
# those spellings; the parity block at the end runs the same logical
# pipelines through the dbplyr walker and this one and demands identical
# edge sets.

skip_if_no_dtplyr_engine <- function() {
  testthat::skip_if_not_installed("dplyr")
  testthat::skip_if_not_installed("data.table")
  testthat::skip_if_not_installed("dtplyr", "1.3.1")
}

# An edge's indirect kinds: multi-kind edges carry data$transformations,
# single-kind ones just data$transformation
edge_kinds <- function(e) {
  e$data$transformations %||% e$data$transformation
}

customers_ldt <- function() {
  dtplyr::lazy_dt(
    data.frame(customer_id = 1L, first_name = "a", email = "a@x.com"),
    name = "customers"
  )
}

orders_ldt <- function() {
  dtplyr::lazy_dt(
    data.frame(order_id = 1L, customer_id = 1L, amount = 1, order_date = 1L),
    name = "orders"
  )
}

test_that("a base lazy_dt maps every column to itself", {
  skip_if_no_dtplyr_engine()

  lineage <- extract_lineage(customers_ldt())

  expect_identical(node_ids(lineage), c("customers", "output"))
  expect_edges(lineage, c(
    "customers.customer_id -> customer_id",
    "customers.first_name -> first_name",
    "customers.email -> email"
  ))
  expect_identical(lineage$metadata$engine, "dtplyr")
  expect_identical(lineage$metadata$dialect, "data.table")
})

test_that("engine = 'r' walks lazy_dt input and records the dtplyr engine", {
  skip_if_no_dtplyr_engine()

  lineage <- extract_lineage(customers_ldt(), engine = "r")
  expect_identical(lineage$metadata$engine, "dtplyr")
})

test_that("select renames trace to their origins", {
  skip_if_no_dtplyr_engine()

  lineage <- customers_ldt() |>
    dplyr::select(id = customer_id, contact = email) |>
    extract_lineage()

  expect_edges(lineage, c(
    "customers.customer_id -> id",
    "customers.email -> contact"
  ))
})

test_that("column-dropping select after a join uses the := NULL form", {
  skip_if_no_dtplyr_engine()

  lineage <- dplyr::left_join(customers_ldt(), orders_ldt(),
    by = "customer_id"
  ) |>
    dplyr::select(customer_id, first_name, amount) |>
    extract_lineage()

  expect_edges(lineage, c(
    "customers.customer_id -> customer_id",
    "customers.first_name -> first_name",
    "orders.amount -> amount"
  ))
})

test_that("transmute expressions fan in from several columns", {
  skip_if_no_dtplyr_engine()

  lineage <- orders_ldt() |>
    dplyr::transmute(total = amount * order_id) |>
    extract_lineage()

  expect_edges(lineage, c(
    "orders.amount -> total",
    "orders.order_id -> total"
  ))
  expect_identical(lineage$edges[[1]]$data$transformation, "transformation")
})

test_that("constant columns appear in the output with no edges", {
  skip_if_no_dtplyr_engine()

  lineage <- orders_ldt() |>
    dplyr::transmute(order_id, flag = 1) |>
    extract_lineage()

  expect_edges(lineage, "orders.order_id -> order_id")
  expect_identical(node_columns(lineage, "output"), c("flag", "order_id"))
})

# --- mutate-family coverage -------------------------------------------

test_that("sequential references inside one call resolve through the block", {
  skip_if_no_dtplyr_engine()

  # transmute(a = , b = a...) renders as a {} block of assignments
  lineage <- orders_ldt() |>
    dplyr::transmute(a = amount * 2, b = a + 1) |>
    extract_lineage()

  expect_edges(lineage, c(
    "orders.amount -> a",
    "orders.amount -> b"
  ))
})

test_that("chained mutates across calls resolve through intermediates", {
  skip_if_no_dtplyr_engine()

  lineage <- orders_ldt() |>
    dplyr::transmute(subtotal = amount + order_id) |>
    dplyr::mutate(total = subtotal * 2) |>
    extract_lineage()

  expect_edges(lineage, c(
    "orders.amount -> subtotal",
    "orders.order_id -> subtotal",
    "orders.amount -> total",
    "orders.order_id -> total"
  ))
})

test_that("self-assigning mutate reads the pre-update column", {
  skip_if_no_dtplyr_engine()

  lineage <- orders_ldt() |>
    dplyr::mutate(amount = amount * 2) |>
    dplyr::select(order_id, amount) |>
    extract_lineage()

  expect_edges(lineage, c(
    "orders.order_id -> order_id",
    "orders.amount -> amount"
  ))
})

test_that("translated conditionals classify as transformations", {
  skip_if_no_dtplyr_engine()

  # if_else() arrives as fifelse(), case_when() as fcase() whose default
  # arm is rep(TRUE, .N) — the .N there must not classify as aggregation
  lineage <- orders_ldt() |>
    dplyr::transmute(
      sized = dplyr::if_else(amount > 5, "hi", "lo"),
      tier = dplyr::case_when(amount > 5 ~ "hi", TRUE ~ "lo")
    ) |>
    extract_lineage()

  types <- vapply(
    lineage$edges,
    function(e) e$data$transformation,
    character(1)
  )
  expect_identical(unique(types), "transformation")
  expect_edges(lineage, c(
    "orders.amount -> sized",
    "orders.amount -> tier"
  ))
})

test_that("row_number() is not an aggregation", {
  skip_if_no_dtplyr_engine()

  # row_number() arrives as seq_len(.N)
  lineage <- orders_ldt() |>
    dplyr::transmute(order_id, r = dplyr::row_number()) |>
    extract_lineage()

  expect_edges(lineage, "orders.order_id -> order_id")
  expect_identical(node_columns(lineage, "output"), c("order_id", "r"))
})

test_that("grouped mutate without aggregates stays quiet", {
  skip_if_no_dtplyr_engine()

  lineage <- orders_ldt() |>
    dplyr::group_by(customer_id) |>
    dplyr::mutate(bumped = amount + 1) |>
    dplyr::ungroup() |>
    dplyr::select(bumped) |>
    extract_lineage(include_indirect = TRUE)

  expect_edges(lineage, "orders.amount -> bumped")
})

test_that("grouped mutate with a window aggregate keeps keys indirect", {
  skip_if_no_dtplyr_engine()

  query <- orders_ldt() |>
    dplyr::group_by(customer_id) |>
    dplyr::mutate(cs = cumsum(amount)) |>
    dplyr::ungroup() |>
    dplyr::select(cs)

  # No OVER clause in data.table code: the grouping key is not a direct
  # source of the windowed column (unlike the dbplyr engine), only an
  # indirect group_by column
  expect_edges(extract_lineage(query), "orders.amount -> cs")

  lineage <- extract_lineage(query, include_indirect = TRUE)
  edge <- Filter(
    function(e) identical(e$sourceHandle, "customer_id"),
    lineage$edges
  )[[1]]
  expect_identical(edge_kinds(edge), "group_by")
})

test_that("filtering on a derived column resolves through to its bases", {
  skip_if_no_dtplyr_engine()

  lineage <- orders_ldt() |>
    dplyr::transmute(order_id, z = amount + 1) |>
    dplyr::filter(z > 2) |>
    extract_lineage(include_indirect = TRUE)

  # z's base is orders.amount, so the filter lands there: as an indirect
  # edge to order_id, and deduplicated against the direct amount -> z edge
  expect_edges(lineage, c(
    "orders.order_id -> order_id",
    "orders.amount -> z",
    "orders.amount -> order_id"
  ))
})

# --- summarise and grouping -------------------------------------------

test_that("group_by + summarise classifies aggregates and keeps keys", {
  skip_if_no_dtplyr_engine()

  lineage <- orders_ldt() |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE), .groups = "drop") |>
    extract_lineage()

  expect_edges(lineage, c(
    "orders.customer_id -> customer_id",
    "orders.amount -> total"
  ))
  total_edge <- Filter(
    function(e) identical(e$targetHandle, "total"),
    lineage$edges
  )[[1]]
  expect_identical(total_edge$data$transformation, "aggregation")
  # The recorded expression is the translated data.table form
  expect_identical(total_edge$data$expression, "sum(amount, na.rm = TRUE)")
})

test_that("n() and n_distinct() translations classify as aggregations", {
  skip_if_no_dtplyr_engine()

  # n() arrives as .N, n_distinct() as uniqueN()
  lineage <- orders_ldt() |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(
      n = dplyr::n(),
      buyers = dplyr::n_distinct(order_id),
      .groups = "drop"
    ) |>
    extract_lineage()

  buyers_edge <- Filter(
    function(e) identical(e$targetHandle, "buyers"),
    lineage$edges
  )[[1]]
  expect_identical(buyers_edge$data$transformation, "aggregation")
  # n() references no column, so it contributes no edges
  expect_identical(
    node_columns(lineage, "output"),
    c("buyers", "customer_id", "n")
  )
})

test_that("across() arrives pre-expanded per column", {
  skip_if_no_dtplyr_engine()

  lineage <- orders_ldt() |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(
      dplyr::across(c(amount, order_id), mean),
      .groups = "drop"
    ) |>
    extract_lineage()

  expect_edges(lineage, c(
    "orders.customer_id -> customer_id",
    "orders.amount -> amount",
    "orders.order_id -> order_id"
  ))
})

test_that("grouped filters unwrap into filter and group_by columns", {
  skip_if_no_dtplyr_engine()

  lineage <- orders_ldt() |>
    dplyr::group_by(customer_id) |>
    dplyr::filter(amount > 1) |>
    dplyr::ungroup() |>
    dplyr::transmute(order_id) |>
    extract_lineage(include_indirect = TRUE)

  expect_edges(lineage, c(
    "orders.order_id -> order_id",
    "orders.amount -> order_id",
    "orders.customer_id -> order_id"
  ))
  kinds <- unlist(lapply(lineage$edges, edge_kinds))
  expect_true("filter" %in% kinds)
  expect_true("group_by" %in% kinds)
})

# --- joins ------------------------------------------------------------

test_that("left joins attribute columns to the correct sides", {
  skip_if_no_dtplyr_engine()

  lineage <- dplyr::left_join(customers_ldt(), orders_ldt(),
    by = "customer_id"
  ) |>
    extract_lineage()

  expect_edges(lineage, c(
    "customers.customer_id -> customer_id",
    "customers.first_name -> first_name",
    "customers.email -> email",
    "orders.order_id -> order_id",
    "orders.amount -> amount",
    "orders.order_date -> order_date"
  ))
})

test_that("join suffix conflicts resolve each side", {
  skip_if_no_dtplyr_engine()

  a <- dtplyr::lazy_dt(data.frame(id = 1L, value = 1), name = "a")
  b <- dtplyr::lazy_dt(data.frame(id = 1L, value = 2), name = "b")

  lineage <- dplyr::inner_join(a, b, by = "id") |> extract_lineage()

  expect_edges(lineage, c(
    "a.id -> id",
    "a.value -> value.x",
    "b.value -> value.y"
  ))
})

test_that("cross-named join keys map through the by= spec", {
  skip_if_no_dtplyr_engine()

  lineage <- dplyr::inner_join(customers_ldt(), orders_ldt(),
    by = c("customer_id" = "order_id")
  ) |>
    extract_lineage()

  expect_edges(lineage, c(
    "customers.customer_id -> customer_id",
    "customers.first_name -> first_name",
    "customers.email -> email",
    "orders.customer_id -> customer_id.y",
    "orders.amount -> amount",
    "orders.order_date -> order_date"
  ))
})

test_that("right join keys attribute to the y side", {
  skip_if_no_dtplyr_engine()

  lineage <- dplyr::right_join(
    customers_ldt(),
    dplyr::select(orders_ldt(), customer_id, amount),
    by = "customer_id"
  ) |>
    extract_lineage()

  expect_edges(lineage, c(
    "orders.customer_id -> customer_id",
    "customers.first_name -> first_name",
    "customers.email -> email",
    "orders.amount -> amount"
  ))
})

test_that("full join keys coalesce both sides", {
  skip_if_no_dtplyr_engine()

  lineage <- dplyr::full_join(
    customers_ldt(),
    dplyr::select(orders_ldt(), customer_id, amount),
    by = "customer_id"
  ) |>
    extract_lineage()

  expect_edges(lineage, c(
    "customers.customer_id -> customer_id",
    "orders.customer_id -> customer_id",
    "customers.first_name -> first_name",
    "customers.email -> email",
    "orders.amount -> amount"
  ))
  key_edges <- Filter(
    function(e) identical(e$targetHandle, "customer_id"),
    lineage$edges
  )
  expect_identical(key_edges[[1]]$data$transformation, "transformation")
})

test_that("semi and anti joins keep only x columns, keys go indirect", {
  skip_if_no_dtplyr_engine()

  for (join in list(dplyr::semi_join, dplyr::anti_join)) {
    query <- join(customers_ldt(), orders_ldt(), by = "customer_id")

    lineage <- extract_lineage(query)
    expect_identical(node_ids(lineage), c("customers", "output"))
    expect_identical(
      node_columns(lineage, "output"),
      c("customer_id", "email", "first_name")
    )

    lineage <- extract_lineage(query, include_indirect = TRUE)
    join_sources <- unique(vapply(
      Filter(
        function(e) "join" %in% edge_kinds(e),
        lineage$edges
      ),
      function(e) e$source,
      character(1)
    ))
    expect_setequal(join_sources, c("customers", "orders"))
  }
})

# --- set operations and row verbs -------------------------------------

test_that("set operations merge sources from both branches", {
  skip_if_no_dtplyr_engine()

  a <- dplyr::transmute(customers_ldt(), id = customer_id)
  b <- dplyr::transmute(orders_ldt(), id = order_id)

  for (op in list(dplyr::union_all, dplyr::setdiff, dplyr::intersect)) {
    expect_edges(extract_lineage(op(a, b)), c(
      "customers.customer_id -> id",
      "orders.order_id -> id"
    ))
  }
})

test_that("distinct passes through, .keep_all keys go indirect", {
  skip_if_no_dtplyr_engine()

  base <- dplyr::select(orders_ldt(), customer_id, amount)
  expect_edges(extract_lineage(dplyr::distinct(base)), c(
    "orders.customer_id -> customer_id",
    "orders.amount -> amount"
  ))

  lineage <- orders_ldt() |>
    dplyr::distinct(customer_id, .keep_all = TRUE) |>
    dplyr::transmute(order_id) |>
    extract_lineage(include_indirect = TRUE)
  filter_edge <- Filter(
    function(e) "filter" %in% edge_kinds(e),
    lineage$edges
  )
  expect_identical(filter_edge[[1]]$sourceHandle, "customer_id")
})

test_that("head and slice orderings keep lineage flowing", {
  skip_if_no_dtplyr_engine()

  expect_edges(
    orders_ldt() |> dplyr::select(order_id) |> head(2) |> extract_lineage(),
    "orders.order_id -> order_id"
  )

  lineage <- orders_ldt() |>
    dplyr::slice_max(amount, n = 1) |>
    dplyr::transmute(order_id) |>
    extract_lineage(include_indirect = TRUE)
  sort_edges <- Filter(
    function(e) "sort" %in% edge_kinds(e),
    lineage$edges
  )
  expect_identical(sort_edges[[1]]$sourceHandle, "amount")
})

test_that("arrange contributes sort columns only", {
  skip_if_no_dtplyr_engine()

  # bare desc(): dtplyr squashes it by name and cannot translate the
  # namespaced spelling
  query <- orders_ldt() |>
    dplyr::arrange(desc(order_date)) |>
    dplyr::transmute(order_id)

  expect_edges(extract_lineage(query), "orders.order_id -> order_id")

  lineage <- extract_lineage(query, include_indirect = TRUE)
  sort_edge <- Filter(
    function(e) "sort" %in% edge_kinds(e),
    lineage$edges
  )[[1]]
  expect_identical(sort_edge$sourceHandle, "order_date")
})

# --- labels, metadata, errors -----------------------------------------

test_that("label attributes on the source frame become column labels", {
  skip_if_no_dtplyr_engine()

  df <- data.frame(order_id = 1L, amount = 2)
  attr(df$amount, "label") <- "Order amount in USD"

  lineage <- dtplyr::lazy_dt(df, name = "orders") |>
    dplyr::select(order_id, amount) |>
    extract_lineage()
  source_node <- Filter(function(n) n$id == "orders", lineage$nodes)[[1]]
  expect_identical(
    source_node$data$columnLabels$amount,
    "Order amount in USD"
  )

  # The labels = argument beats the attribute
  lineage <- dtplyr::lazy_dt(df, name = "orders") |>
    dplyr::select(order_id, amount) |>
    extract_lineage(labels = list(orders = c(amount = "Override")))
  source_node <- Filter(function(n) n$id == "orders", lineage$nodes)[[1]]
  expect_identical(source_node$data$columnLabels$amount, "Override")
})

test_that("the models metadata records the data.table call", {
  skip_if_no_dtplyr_engine()

  lineage <- orders_ldt() |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total = sum(amount), .groups = "drop") |>
    extract_lineage()

  expect_match(lineage$metadata$models$output$sql, "keyby", fixed = TRUE)
  expect_identical(lineage$metadata$models$output$engine, "dtplyr")
  expect_identical(lineage$metadata$models$output$dialect, "data.table")
})

test_that("mixed dbplyr + dtplyr pipelines collapse metadata to mixed", {
  skip_if_no_dtplyr_engine()
  skip_if_not_installed("dbplyr", "2.5.0")

  lineage <- extract_lineage(list(
    silver = dbplyr::lazy_frame(
      customer_id = 1L, amount = 1,
      .name = "raw_orders"
    ) |>
      dplyr::transmute(customer_id, amount),
    gold = dtplyr::lazy_dt(
      data.frame(customer_id = 1L, amount = 1),
      name = "silver"
    ) |>
      dplyr::group_by(customer_id) |>
      dplyr::summarise(total = sum(amount), .groups = "drop")
  ))

  expect_identical(lineage$metadata$engine, "mixed")
  expect_identical(lineage$metadata$dialect, "mixed")
  expect_identical(node_ids(lineage), c("gold", "raw_orders", "silver"))
})

test_that("engine = 'sqlglot' refuses dtplyr input with a pointer", {
  skip_if_no_dtplyr_engine()

  expect_error(
    extract_lineage(customers_ldt(), engine = "sqlglot"),
    "compile to data.table code"
  )
})

test_that("group_modify raises the classed condition, auto adds context", {
  skip_if_no_dtplyr_engine()

  # group_modify.dtplyr_step ensyms its .f, so it needs a named function
  first_row <- function(data, key) head(data, 1)
  query <- orders_ldt() |>
    dplyr::group_by(customer_id) |>
    dplyr::group_modify(first_row)

  expect_error(
    extract_lineage(query, engine = "r"),
    class = "dplyneage_unsupported_lineage"
  )
  expect_error(
    extract_lineage(query, engine = "auto"),
    "cannot take over"
  )
})

test_that("the plain data frame error now points at lazy_dt too", {
  expect_error(extract_lineage(data.frame(x = 1)), "lazy_dt")
})

# --- parity with the dbplyr engine ------------------------------------

test_that("the dbplyr and dtplyr walkers agree on shared pipelines", {
  skip_if_no_dtplyr_engine()
  skip_if_not_installed("dbplyr", "2.5.0")

  cust_df <- data.frame(customer_id = 1L, first_name = "a", email = "e")
  ords_df <- data.frame(
    order_id = 1L, customer_id = 1L, amount = 1, order_date = 1L
  )

  # edge_set() plus each edge's direct type and indirect kind set, so
  # parity covers classification, not just topology
  typed_edge_set <- function(lineage) {
    sort(vapply(
      lineage$edges,
      function(e) {
        paste0(
          e$source, ".", e$sourceHandle, " -> ", e$targetHandle,
          " [", e$data$transformation %||% "", "|",
          paste(sort(e$data$transformations %||% character()), collapse = ","),
          "]"
        )
      },
      character(1)
    ))
  }

  # Windowed pipelines are excluded: data.table has no OVER clause, so
  # grouped window columns diverge by design (keys indirect, not direct)
  shapes <- list(
    rename_select = function(c, o) {
      dplyr::select(c, id = customer_id, contact = email)
    },
    chained_mutate = function(c, o) {
      o |>
        dplyr::transmute(subtotal = amount + order_id) |>
        dplyr::mutate(total = subtotal * 2)
    },
    sequential_refs = function(c, o) {
      dplyr::transmute(o, a = amount * 2, b = a + 1)
    },
    conditional_mutate = function(c, o) {
      dplyr::transmute(o, tier = dplyr::if_else(amount > 5, "hi", "lo"))
    },
    mutate_then_filter = function(c, o) {
      o |> dplyr::transmute(order_id, z = amount + 1) |> dplyr::filter(z > 2)
    },
    filter_select = function(c, o) {
      o |> dplyr::filter(amount > 100) |> dplyr::select(order_id, amount)
    },
    summarise_grouped = function(c, o) {
      o |>
        dplyr::group_by(customer_id) |>
        dplyr::summarise(
          total = sum(amount, na.rm = TRUE),
          n = dplyr::n(),
          .groups = "drop"
        )
    },
    left_join_select = function(c, o) {
      dplyr::left_join(c, o, by = "customer_id") |>
        dplyr::select(customer_id, first_name, amount)
    },
    inner_join_crosskey = function(c, o) {
      dplyr::inner_join(c, o, by = c("customer_id" = "order_id"))
    },
    right_join = function(c, o) {
      dplyr::right_join(
        c, dplyr::select(o, customer_id, amount),
        by = "customer_id"
      )
    },
    full_join = function(c, o) {
      dplyr::full_join(
        c, dplyr::select(o, customer_id, amount),
        by = "customer_id"
      )
    },
    semi_join = function(c, o) dplyr::semi_join(c, o, by = "customer_id"),
    anti_join = function(c, o) dplyr::anti_join(c, o, by = "customer_id"),
    union_all = function(c, o) {
      dplyr::union_all(
        dplyr::transmute(c, id = customer_id),
        dplyr::transmute(o, id = order_id)
      )
    },
    setdiff = function(c, o) {
      dplyr::setdiff(
        dplyr::transmute(c, id = customer_id),
        dplyr::transmute(o, id = order_id)
      )
    },
    distinct = function(c, o) {
      o |> dplyr::select(customer_id, amount) |> dplyr::distinct()
    },
    arrange_select = function(c, o) {
      o |> dplyr::arrange(desc(order_date)) |> dplyr::select(order_id)
    }
  )

  for (include_indirect in c(FALSE, TRUE)) {
    for (nm in names(shapes)) {
      shape <- shapes[[nm]]
      dbplyr_lineage <- extract_lineage(
        shape(
          dbplyr::lazy_frame(cust_df, .name = "customers"),
          dbplyr::lazy_frame(ords_df, .name = "orders")
        ),
        engine = "r", include_indirect = include_indirect
      )
      dtplyr_lineage <- extract_lineage(
        shape(
          dtplyr::lazy_dt(cust_df, name = "customers"),
          dtplyr::lazy_dt(ords_df, name = "orders")
        ),
        include_indirect = include_indirect
      )
      label <- paste0(nm, if (include_indirect) " (indirect)")
      expect_identical(
        typed_edge_set(dtplyr_lineage), typed_edge_set(dbplyr_lineage),
        label = label
      )
      expect_identical(
        node_ids(dtplyr_lineage), node_ids(dbplyr_lineage),
        label = label
      )
    }
  }
})
