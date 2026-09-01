# The duckplyr engine renders the frame's duckdb relation to SQL,
# rewrites it (pointer scans to named tables, aggregate macros to
# standard spellings), and analyzes it with the sqlglot engine. These
# tests use real duckplyr objects; the shapes pin the rewrite rules and
# the documented wrapper-SELECT-* gap.

skip_if_no_duckplyr_engine <- function() {
  skip_if_no_sqlglot()
  testthat::skip_if_not_installed("dplyr")
  testthat::skip_if_not_installed("duckdb")
  testthat::skip_if_not_installed("duckplyr", "1.0.0")
  testthat::skip_if_not(
    duckplyr_engine_available(),
    "duckdb's relational API is not available"
  )
}

points_ddt <- function() {
  duckplyr::as_duckdb_tibble(data.frame(x = 1:3, g = c("a", "b", "a")))
}

weights_ddt <- function() {
  duckplyr::as_duckdb_tibble(data.frame(g = c("a", "b"), w = c(10, 20)))
}

test_that("a base duckplyr frame maps every column to itself", {
  skip_if_no_duckplyr_engine()

  lineage <- points_ddt() |>
    dplyr::mutate(z = x + 1) |>
    extract_lineage()

  expect_edges(lineage, c(
    "df.x -> x",
    "df.g -> g",
    "df.x -> z"
  ))
  expect_identical(lineage$metadata$engine, "duckplyr")
  expect_identical(lineage$metadata$dialect, "duckdb")
  expect_identical(lineage$metadata$models$output$namespace, "duckdb")
})

test_that("the recorded SQL is rewritten and deterministic", {
  skip_if_no_duckplyr_engine()

  sql <- points_ddt() |>
    dplyr::mutate(z = x + 1) |>
    extract_lineage() |>
    (\(l) l$metadata$models$output$sql)()

  # pointer scans and session-specific aliases are normalized away
  expect_match(sql, "FROM df AS q1", fixed = TRUE)
  expect_no_match(sql, "r_dataframe_scan")
  expect_no_match(sql, "dataframe_[0-9]")
})

test_that("chained mutates resolve through the nested projections", {
  skip_if_no_duckplyr_engine()

  lineage <- points_ddt() |>
    dplyr::mutate(a = x + 1) |>
    dplyr::mutate(b = a * 2) |>
    extract_lineage()

  expect_edges(lineage, c(
    "df.x -> x",
    "df.g -> g",
    "df.x -> a",
    "df.x -> b"
  ))
})

test_that("conditional mutates classify as transformations", {
  skip_if_no_duckplyr_engine()

  lineage <- points_ddt() |>
    dplyr::mutate(t = dplyr::if_else(x > 1, "hi", "lo")) |>
    extract_lineage()

  t_edge <- Filter(
    function(e) identical(e$targetHandle, "t"),
    lineage$edges
  )[[1]]
  expect_identical(t_edge$data$transformation, "transformation")
})

test_that("mutate-then-filter keeps exact sources through the wrapper", {
  skip_if_no_duckplyr_engine()

  lineage <- points_ddt() |>
    dplyr::mutate(z = x + 1) |>
    dplyr::filter(z > 2) |>
    extract_lineage()

  # Documented gap: the verb after a projection wraps it in SELECT *,
  # which re-classifies the computed column as identity — but its
  # source stays exactly df.x
  expect_edges(lineage, c(
    "df.x -> x",
    "df.g -> g",
    "df.x -> z"
  ))
  z_edge <- Filter(
    function(e) identical(e$targetHandle, "z"),
    lineage$edges
  )[[1]]
  expect_identical(z_edge$data$transformation, "identity")
})

test_that("filter-only pipelines recover columns via the retry schema", {
  skip_if_no_duckplyr_engine()

  lineage <- points_ddt() |>
    dplyr::filter(x > 1) |>
    extract_lineage(include_indirect = TRUE)

  expect_edges(lineage, c(
    "df.x -> x",
    "df.g -> g",
    "df.x -> g"
  ))
})

test_that("summarise classifies aggregates and keys group columns", {
  skip_if_no_duckplyr_engine()

  lineage <- points_ddt() |>
    dplyr::summarise(
      n = dplyr::n(),
      nd = dplyr::n_distinct(x),
      m = mean(x),
      s = sum(x),
      .by = g
    ) |>
    extract_lineage(include_indirect = TRUE)

  types <- vapply(
    Filter(
      function(e) {
        # direct aggregate edges only; the group key also fans out
        # indirect group_by edges to these targets
        e$targetHandle %in% c("nd", "m", "s") &&
          identical(e$sourceHandle, "x")
      },
      lineage$edges
    ),
    function(e) e$data$transformation,
    character(1)
  )
  expect_identical(unique(types), "aggregation")
  # n() reads no column; the grouping key arrives as identity plus its
  # group_by role is covered by the direct edge dedup
  group_edge <- Filter(
    function(e) identical(e$targetHandle, "g"),
    lineage$edges
  )[[1]]
  expect_identical(group_edge$data$transformation, "identity")
})

test_that("join keys coalesce both sides and suffixes are stripped", {
  skip_if_no_duckplyr_engine()

  lineage <- dplyr::left_join(points_ddt(), weights_ddt(), by = "g") |>
    extract_lineage(include_indirect = TRUE)

  expect_edges(lineage, c(
    "df_1.x -> x",
    "df_1.g -> g",
    "df_2.g -> g",
    "df_2.w -> w",
    "df_1.g -> x",
    "df_1.g -> w",
    "df_2.g -> x",
    "df_2.g -> w"
  ))
  key_edges <- Filter(
    function(e) identical(e$targetHandle, "g"),
    lineage$edges
  )
  for (edge in key_edges) {
    expect_identical(edge$data$transformation, "transformation")
  }
  # duckplyr's internal g_x/g_y join spellings never surface
  handles <- vapply(lineage$edges, function(e) e$sourceHandle, character(1))
  expect_false(any(grepl("_x$|_y$", handles)))
})

test_that("semi and anti joins keep x columns and mark keys indirect", {
  skip_if_no_duckplyr_engine()

  for (join in list(dplyr::semi_join, dplyr::anti_join)) {
    lineage <- join(points_ddt(), weights_ddt(), by = "g") |>
      extract_lineage(include_indirect = TRUE)

    expect_identical(node_columns(lineage, "output"), c("g", "x"))
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
    expect_true("df_2" %in% join_tables)
  }
})

test_that("arrange contributes sort columns through the retry schema", {
  skip_if_no_duckplyr_engine()

  lineage <- points_ddt() |>
    dplyr::arrange(dplyr::desc(x)) |>
    extract_lineage(include_indirect = TRUE)

  sort_edges <- Filter(
    function(e) {
      "sort" %in% (e$data$transformations %||% e$data$transformation)
    },
    lineage$edges
  )
  expect_identical(unique(vapply(
    sort_edges,
    function(e) e$sourceHandle,
    character(1)
  )), "x")
})

test_that("distinct projects identity lineage", {
  skip_if_no_duckplyr_engine()

  lineage <- points_ddt() |>
    dplyr::distinct(g) |>
    extract_lineage()

  expect_edges(lineage, "df.g -> g")
})

test_that("set operations keep both branches as sources", {
  skip_if_no_duckplyr_engine()

  lineage <- dplyr::union_all(
    dplyr::select(points_ddt(), g),
    dplyr::select(weights_ddt(), g)
  ) |>
    extract_lineage()

  expect_edges(lineage, c(
    "df_1.g -> g",
    "df_2.g -> g"
  ))
})

test_that("a frame unioned with itself still extracts", {
  skip_if_no_duckplyr_engine()

  d <- points_ddt()
  lineage <- dplyr::union_all(d, d) |> extract_lineage()

  # duckplyr may render one shared scan or one per branch; either way
  # every source is an in-memory scan feeding both columns
  expect_identical(node_columns(lineage, "output"), c("g", "x"))
  sources <- vapply(lineage$edges, function(e) e$source, character(1))
  expect_true(all(grepl("^df", sources)))
})

test_that("file-backed frames keep the path as the table and get types", {
  skip_if_no_duckplyr_engine()
  skip_if_not_installed("withr")

  dir <- withr::local_tempdir()
  path <- file.path(dir, "TestOrders.csv")
  write.csv(data.frame(oid = 1:2, amt = c(5, 6)), path, row.names = FALSE)

  lineage <- duckplyr::read_csv_duckdb(path) |>
    dplyr::mutate(big = amt * 2) |>
    extract_lineage()

  expect_edges(lineage, c(
    paste0(path, ".oid -> oid"),
    paste0(path, ".amt -> amt"),
    paste0(path, ".amt -> big")
  ))
  source_node <- Filter(function(n) n$id == path, lineage$nodes)[[1]]
  expect_identical(source_node$data$columnTypes$amt, "BIGINT")

  # a star top over the file binds through the DESCRIBE schema
  star <- duckplyr::read_csv_duckdb(path) |>
    dplyr::filter(amt > 5) |>
    extract_lineage()
  expect_edges(star, c(
    paste0(path, ".oid -> oid"),
    paste0(path, ".amt -> amt")
  ))
})

test_that("compute() frames read from the materialized temp table", {
  skip_if_no_duckplyr_engine()

  lineage <- points_ddt() |>
    dplyr::mutate(z = x + 1) |>
    dplyr::compute() |>
    dplyr::mutate(w = z * 2) |>
    extract_lineage()

  temp <- setdiff(node_ids(lineage), "output")
  expect_length(temp, 1)
  expect_match(temp, "^duckplyr_")
  expect_edges(lineage, c(
    paste0(temp, ".x -> x"),
    paste0(temp, ".g -> g"),
    paste0(temp, ".z -> z"),
    paste0(temp, ".z -> w")
  ))
})

test_that("both prudence modes extract", {
  skip_if_no_duckplyr_engine()

  for (prudence in c("lavish", "stingy")) {
    lineage <- duckplyr::duckdb_tibble(x = 1:3, .prudence = prudence) |>
      dplyr::mutate(y = x + 1) |>
      extract_lineage()
    expect_edges(lineage, c("df.x -> x", "df.x -> y"))
  }
})

test_that("a materialized frame still extracts", {
  skip_if_no_duckplyr_engine()

  q <- points_ddt() |> dplyr::mutate(z = x + 1)
  invisible(nrow(q)) # forces materialization

  expect_edges(extract_lineage(q), c(
    "df.x -> x",
    "df.g -> g",
    "df.x -> z"
  ))
})

test_that("dbplyr-backed frames agree with the dbplyr engine", {
  skip_if_no_duckplyr_engine()
  skip_if_not_installed("dbplyr", "2.5.0")
  skip_if_not_installed("withr")

  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(
    con, "orders",
    data.frame(order_id = 1:2, customer_id = 1:2, amount = c(5, 6))
  )

  shape <- function(x) {
    x |>
      dplyr::mutate(v = amount * 2) |>
      dplyr::select(order_id, v)
  }
  duckplyr_lineage <- extract_lineage(
    shape(duckplyr::as_duckdb_tibble(dplyr::tbl(con, "orders")))
  )
  dbplyr_lineage <- extract_lineage(
    shape(dplyr::tbl(con, "orders")),
    engine = "r"
  )

  expect_identical(edge_set(duckplyr_lineage), edge_set(dbplyr_lineage))
  expect_identical(node_ids(duckplyr_lineage), node_ids(dbplyr_lineage))
  expect_identical(duckplyr_lineage$metadata$engine, "duckplyr")
})

test_that("engine choices route and refuse correctly", {
  skip_if_no_duckplyr_engine()

  q <- points_ddt() |> dplyr::mutate(z = x + 1)

  forced <- extract_lineage(q, engine = "sqlglot")
  expect_identical(forced$metadata$engine, "duckplyr")

  expect_error(
    extract_lineage(q, engine = "r"),
    "not inspectable from R"
  )
})

test_that("fallen-back pipelines get the data frame error with context", {
  skip_if_no_duckplyr_engine()

  # grouped mutate falls back to eager dplyr: the result is a plain
  # tibble and the lazy tree is gone
  fallen <- points_ddt() |>
    dplyr::group_by(g) |>
    dplyr::mutate(s = sum(x))
  expect_s3_class(fallen, "grouped_df")
  expect_error(extract_lineage(fallen), "fell back to eager dplyr")
})
