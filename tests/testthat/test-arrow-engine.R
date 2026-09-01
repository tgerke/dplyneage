# The arrow engine walks arrow_dplyr_query structures natively — no
# Python involved. In-memory Tables have no names, so nodes are
# arrow_table, arrow_table_2, ... in walk order; the parity block maps
# those onto the dbplyr fixtures' names before comparing.

skip_if_no_arrow_engine <- function() {
  testthat::skip_if_not_installed("dplyr")
  testthat::skip_if_not_installed("arrow", "17.0.0")
}

points_at <- function() {
  arrow::arrow_table(data.frame(x = 1:3, g = c("a", "b", "a")))
}

weights_at <- function() {
  arrow::arrow_table(data.frame(g = c("a", "b"), w = c(10, 20)))
}

test_that("a bare arrow Table maps every column to itself", {
  skip_if_no_arrow_engine()

  lineage <- extract_lineage(points_at())

  expect_identical(node_ids(lineage), c("arrow_table", "output"))
  expect_edges(lineage, c(
    "arrow_table.x -> x",
    "arrow_table.g -> g"
  ))
  expect_identical(lineage$metadata$engine, "arrow")
  expect_identical(lineage$metadata$dialect, "arrow")
  # no query text exists for Acero plans
  expect_null(lineage$metadata$models$output$sql)
})

test_that("chained mutates fan in through inlined expressions", {
  skip_if_no_arrow_engine()

  lineage <- points_at() |>
    dplyr::mutate(a = x + 1, b = a * 2) |>
    extract_lineage()

  expect_edges(lineage, c(
    "arrow_table.x -> x",
    "arrow_table.g -> g",
    "arrow_table.x -> a",
    "arrow_table.x -> b"
  ))
  b_edge <- Filter(
    function(e) identical(e$targetHandle, "b"),
    lineage$edges
  )[[1]]
  expect_identical(b_edge$data$transformation, "transformation")
})

test_that("renames keep identity lineage", {
  skip_if_no_arrow_engine()

  lineage <- points_at() |>
    dplyr::select(id = x, grp = g) |>
    extract_lineage()

  expect_edges(lineage, c(
    "arrow_table.x -> id",
    "arrow_table.g -> grp"
  ))
  for (edge in lineage$edges) {
    expect_identical(edge$data$transformation, "identity")
  }
})

test_that("conditional mutates classify as transformations", {
  skip_if_no_arrow_engine()

  lineage <- points_at() |>
    dplyr::transmute(t = dplyr::if_else(x > 1, "hi", "lo")) |>
    extract_lineage()

  expect_edges(lineage, "arrow_table.x -> t")
  expect_identical(lineage$edges[[1]]$data$transformation, "transformation")
})

test_that("filters contribute indirect columns only", {
  skip_if_no_arrow_engine()

  query <- points_at() |> dplyr::filter(x > 1)

  expect_edges(extract_lineage(query), c(
    "arrow_table.x -> x",
    "arrow_table.g -> g"
  ))

  lineage <- extract_lineage(query, include_indirect = TRUE)
  filter_edge <- Filter(
    function(e) {
      "filter" %in% (e$data$transformations %||% e$data$transformation)
    },
    lineage$edges
  )[[1]]
  expect_identical(filter_edge$sourceHandle, "x")
})

test_that("summarise nests the query and classifies aggregates", {
  skip_if_no_arrow_engine()

  lineage <- points_at() |>
    dplyr::group_by(g) |>
    dplyr::summarise(total = sum(x), n = dplyr::n()) |>
    extract_lineage(include_indirect = TRUE)

  expect_edges(lineage, c(
    "arrow_table.g -> g",
    "arrow_table.x -> total",
    "arrow_table.g -> total",
    "arrow_table.g -> n"
  ))
  total_edge <- Filter(
    function(e) {
      identical(e$targetHandle, "total") && identical(e$sourceHandle, "x")
    },
    lineage$edges
  )[[1]]
  expect_identical(total_edge$data$transformation, "aggregation")
  expect_identical(total_edge$data$expression, "sum(x)")
  # n() reads no column but still appears in the output
  expect_identical(node_columns(lineage, "output"), c("g", "n", "total"))
})

test_that("mutate after summarise recurses through the nested query", {
  skip_if_no_arrow_engine()

  lineage <- points_at() |>
    dplyr::group_by(g) |>
    dplyr::summarise(total = sum(x), n = dplyr::n()) |>
    dplyr::mutate(scaled = total / n) |>
    extract_lineage()

  scaled_edges <- Filter(
    function(e) identical(e$targetHandle, "scaled"),
    lineage$edges
  )
  expect_identical(
    vapply(scaled_edges, function(e) e$sourceHandle, character(1)),
    "x"
  )
  expect_identical(scaled_edges[[1]]$data$transformation, "transformation")
})

test_that("left joins attribute columns to the correct sides", {
  skip_if_no_arrow_engine()

  lineage <- points_at() |>
    dplyr::left_join(weights_at(), by = "g") |>
    extract_lineage()

  expect_edges(lineage, c(
    "arrow_table.x -> x",
    "arrow_table.g -> g",
    "arrow_table_2.w -> w"
  ))
})

test_that("full join keys coalesce both sides with suffixes applied", {
  skip_if_no_arrow_engine()

  a <- arrow::arrow_table(data.frame(id = 1L, value = 1))
  b <- arrow::arrow_table(data.frame(id = 1L, value = 2, w = 3))

  lineage <- dplyr::full_join(a, b, by = "id") |> extract_lineage()

  expect_edges(lineage, c(
    "arrow_table.id -> id",
    "arrow_table_2.id -> id",
    "arrow_table.value -> value.x",
    "arrow_table_2.value -> value.y",
    "arrow_table_2.w -> w"
  ))
  key_edges <- Filter(
    function(e) identical(e$targetHandle, "id"),
    lineage$edges
  )
  for (edge in key_edges) {
    expect_identical(edge$data$transformation, "transformation")
  }
})

test_that("right join keys attribute to the y side", {
  skip_if_no_arrow_engine()

  a <- arrow::arrow_table(data.frame(id = 1L, value = 1))
  b <- arrow::arrow_table(data.frame(id = 1L, value = 2, w = 3))

  lineage <- dplyr::right_join(a, b, by = "id") |> extract_lineage()

  expect_edges(lineage, c(
    "arrow_table_2.id -> id",
    "arrow_table.value -> value.x",
    "arrow_table_2.value -> value.y",
    "arrow_table_2.w -> w"
  ))
})

test_that("semi and anti joins keep x columns and mark keys indirect", {
  skip_if_no_arrow_engine()

  for (join in list(dplyr::semi_join, dplyr::anti_join)) {
    query <- join(points_at(), weights_at(), by = "g")

    lineage <- extract_lineage(query)
    expect_identical(node_ids(lineage), c("arrow_table", "output"))

    lineage <- extract_lineage(query, include_indirect = TRUE)
    join_tables <- unique(vapply(
      Filter(
        function(e) {
          "join" %in% (e$data$transformations %||% e$data$transformation)
        },
        lineage$edges
      ),
      function(e) e$source,
      character(1)
    ))
    expect_setequal(join_tables, c("arrow_table", "arrow_table_2"))
  }
})

test_that("union_all merges sources from both branches", {
  skip_if_no_arrow_engine()

  lineage <- dplyr::union_all(
    dplyr::select(points_at(), g),
    dplyr::select(weights_at(), g)
  ) |>
    extract_lineage()

  expect_edges(lineage, c(
    "arrow_table.g -> g",
    "arrow_table_2.g -> g"
  ))
})

test_that("distinct rewrites stay identity, .keep_all included", {
  skip_if_no_arrow_engine()

  expect_edges(
    points_at() |> dplyr::distinct(g) |> extract_lineage(),
    "arrow_table.g -> g"
  )

  lineage <- points_at() |>
    dplyr::distinct(g, .keep_all = TRUE) |>
    extract_lineage()
  expect_edges(lineage, c(
    "arrow_table.x -> x",
    "arrow_table.g -> g"
  ))
  for (edge in lineage$edges) {
    expect_identical(edge$data$transformation, "identity")
  }
})

test_that("arrange contributes sort columns only", {
  skip_if_no_arrow_engine()

  lineage <- points_at() |>
    dplyr::arrange(dplyr::desc(x)) |>
    extract_lineage(include_indirect = TRUE)

  sort_edge <- Filter(
    function(e) {
      "sort" %in% (e$data$transformations %||% e$data$transformation)
    },
    lineage$edges
  )[[1]]
  expect_identical(sort_edge$sourceHandle, "x")
})

test_that("grouped mutate walks arrow's self-join workaround", {
  skip_if_no_arrow_engine()

  lineage <- points_at() |>
    dplyr::group_by(g) |>
    dplyr::mutate(cs = sum(x)) |>
    dplyr::ungroup() |>
    extract_lineage(include_indirect = TRUE)

  # the window value compiles to an aggregation joined back on the key
  cs_edge <- Filter(
    function(e) {
      identical(e$targetHandle, "cs") && identical(e$sourceHandle, "x")
    },
    lineage$edges
  )[[1]]
  expect_identical(cs_edge$data$transformation, "aggregation")
  key_kinds <- unlist(lapply(
    Filter(function(e) identical(e$sourceHandle, "g"), lineage$edges),
    function(e) e$data$transformations %||% e$data$transformation
  ))
  expect_true("group_by" %in% key_kinds)
  # one table: the workaround joins the query against itself
  expect_identical(node_ids(lineage), c("arrow_table", "output"))
})

test_that("a table joined with itself stays one node", {
  skip_if_no_arrow_engine()

  t <- points_at()
  lineage <- t |>
    dplyr::left_join(dplyr::select(t, g, x2 = x), by = "g") |>
    extract_lineage()

  expect_identical(node_ids(lineage), c("arrow_table", "output"))
  expect_edges(lineage, c(
    "arrow_table.x -> x",
    "arrow_table.g -> g",
    "arrow_table.x -> x2"
  ))
})

test_that("schema types and metadata labels reach the nodes", {
  skip_if_no_arrow_engine()

  df <- data.frame(x = 1:3, g = c("a", "b", "a"))
  attr(df$x, "label") <- "The X"

  lineage <- arrow::arrow_table(df) |>
    dplyr::select(x, g) |>
    extract_lineage()
  source_node <- Filter(
    function(n) n$id == "arrow_table",
    lineage$nodes
  )[[1]]
  expect_identical(source_node$data$columnTypes$x, "int32")
  expect_identical(source_node$data$columnTypes$g, "string")
  expect_identical(source_node$data$columnLabels$x, "The X")

  # the labels = argument beats the metadata attribute
  lineage <- arrow::arrow_table(df) |>
    dplyr::select(x) |>
    extract_lineage(labels = list(arrow_table = c(x = "Override")))
  source_node <- Filter(
    function(n) n$id == "arrow_table",
    lineage$nodes
  )[[1]]
  expect_identical(source_node$data$columnLabels$x, "Override")
})

test_that("file datasets keep their path and record the file namespace", {
  skip_if_no_arrow_engine()
  skip_if_not_installed("withr")

  dir <- withr::local_tempdir()
  arrow::write_dataset(data.frame(x = 1:3, g = c("a", "b", "a")), dir)

  lineage <- arrow::open_dataset(dir) |>
    dplyr::mutate(z = x + 1) |>
    extract_lineage()

  source_id <- setdiff(node_ids(lineage), "output")
  expect_length(source_id, 1)
  expect_match(source_id, "parquet$")
  expect_identical(lineage$metadata$models$output$namespace, "file")
})

test_that("engine choices route and refuse correctly", {
  skip_if_no_arrow_engine()

  query <- points_at() |> dplyr::mutate(z = x + 1)

  forced <- extract_lineage(query, engine = "r")
  expect_identical(forced$metadata$engine, "arrow")

  expect_error(
    extract_lineage(query, engine = "sqlglot"),
    "Acero query plans"
  )
})

# --- parity with the dbplyr engine ------------------------------------

test_that("the dbplyr and arrow walkers agree on shared pipelines", {
  skip_if_no_arrow_engine()
  skip_if_not_installed("dbplyr", "2.5.0")

  cust_df <- data.frame(customer_id = 1L, first_name = "a", email = "e")
  ords_df <- data.frame(
    order_id = 1L, customer_id = 1L, amount = 1, order_date = 1L
  )

  # arrow Tables are nameless: nodes come out arrow_table/arrow_table_2
  # in walk order, mapped here onto the dbplyr fixtures' names
  renamed <- function(strings, map) {
    for (nm in names(map)) {
      strings <- gsub(paste0("\\b", nm, "\\."), paste0(map[[nm]], "."), strings)
    }
    sort(strings)
  }

  # windowed/grouped-mutate shapes are excluded: arrow compiles them to
  # an aggregation self-join, which classifies differently by design
  shapes <- list(
    mutate_select = function(c, o) {
      o |>
        dplyr::mutate(total = amount + order_id) |>
        dplyr::select(order_id, total)
    },
    conditional = function(c, o) {
      o |> dplyr::transmute(t = dplyr::if_else(amount > 5, "hi", "lo"))
    },
    filter_pipeline = function(c, o) o |> dplyr::filter(amount > 100),
    summarise_grouped = function(c, o) {
      o |>
        dplyr::group_by(customer_id) |>
        dplyr::summarise(total = sum(amount), n = dplyr::n())
    },
    left_join = function(c, o) dplyr::left_join(c, o, by = "customer_id"),
    full_join = function(c, o) {
      dplyr::full_join(
        c, dplyr::select(o, customer_id, amount),
        by = "customer_id"
      )
    },
    semi_join = function(c, o) dplyr::semi_join(c, o, by = "customer_id"),
    union_all = function(c, o) {
      dplyr::union_all(
        dplyr::transmute(c, id = customer_id),
        dplyr::transmute(o, id = order_id)
      )
    },
    distinct = function(c, o) {
      o |> dplyr::select(customer_id, amount) |> dplyr::distinct()
    },
    arrange = function(c, o) o |> dplyr::arrange(order_date)
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
      arrow_lineage <- extract_lineage(
        shape(arrow::arrow_table(cust_df), arrow::arrow_table(ords_df)),
        include_indirect = include_indirect
      )
      # map arrow's placeholder names onto the fixture names, in walk
      # order: single-source shapes only ever see arrow_table
      uses_both <- any(grepl("arrow_table_2", typed_edge_set(arrow_lineage)))
      map <- if (uses_both) {
        first <- if (nm %in% c("mutate_select", "conditional",
                               "filter_pipeline", "summarise_grouped",
                               "distinct", "arrange")) {
          "orders"
        } else {
          "customers"
        }
        c(arrow_table_2 = "orders", arrow_table = first)
      } else {
        first <- if (nm %in% c("left_join", "full_join", "semi_join")) {
          "customers"
        } else if (identical(nm, "union_all")) {
          "customers"
        } else {
          "orders"
        }
        c(arrow_table = first)
      }
      label <- paste0(nm, if (include_indirect) " (indirect)")
      expect_identical(
        renamed(typed_edge_set(arrow_lineage), map),
        typed_edge_set(dbplyr_lineage),
        label = label
      )
    }
  }
})

# --- mutate family ----------------------------------------------------

test_that("mutate-family shapes match the shared expectations", {
  skip_if_no_arrow_engine()

  run_mutate_shapes(
    engine = "arrow",
    input = function(df) arrow::arrow_table(df),
    extract = function(x, ii) extract_lineage(x, include_indirect = ii),
    source = "arrow_table"
  )
})
