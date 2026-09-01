# Engine dispatch: extract_lineage() accepts several kinds of lazy input,
# each analyzed by its own engine. lineage_input_kind() maps an object to
# its kind; lineage_native_engines() describes the engines that walk a
# lazy structure directly (everything except the dbplyr walker and the
# sqlglot SQL parser, which predate the registry and keep their own
# branches in extract_lineage_data()).

#' Which lineage input kind is this object?
#'
#' The duckplyr check must run before the data.frame check: a duckplyr_df
#' is a data.frame subclass, and the plain-data-frame error would swallow
#' it otherwise.
#' @noRd
lineage_input_kind <- function(x) {
  if (inherits(x, "tbl_lazy")) {
    return("dbplyr")
  }
  if (inherits(x, "dtplyr_step")) {
    return("dtplyr")
  }
  if (inherits(x, "duckplyr_df")) {
    return("duckplyr")
  }
  if (
    inherits(
      x,
      c("arrow_dplyr_query", "Dataset", "Table", "RecordBatch",
        "RecordBatchReader")
    )
  ) {
    return("arrow")
  }
  # Plain data frames would otherwise fall through to the sqlglot branch
  # and fail with errors about Python or SQL strings that never mention
  # the actual fix
  if (is.data.frame(x)) {
    stop_plain_data_frame()
  }
  if (is.character(x)) {
    return("sql")
  }
  stop(
    "sql must be a character string, a lazy table (dbplyr, dtplyr, ",
    "duckplyr, or arrow), or a named list of them",
    call. = FALSE
  )
}

#' The error for plain data frames, with every wrapper that fixes it
#' @noRd
stop_plain_data_frame <- function() {
  stop(
    "extract_lineage() reads lineage from a lazy query tree, which a ",
    "plain data frame doesn't have. Wrap it first: ",
    "dbplyr::tbl_lazy(df, name = \"df\") needs no database and is ",
    "enough for lineage; dtplyr::lazy_dt(df, name = \"df\") and ",
    "duckplyr::as_duckdb_tibble(df) analyze the same pipeline on those ",
    "backends; dbplyr::memdb_frame() or ",
    "copy_to(dbplyr::memdb(), df, name = \"df\") make the same ",
    "pipeline also collectable. If this frame started as a duckplyr ",
    "pipeline, a verb fell back to eager dplyr and the lazy tree is ",
    "gone; Sys.setenv(DUCKPLYR_FALLBACK_INFO = TRUE) shows which step. ",
    "See vignette(\"getting-started\").",
    call. = FALSE
  )
}

#' Registry of native lineage engines
#'
#' One entry per input kind that is walked by its own engine. Fields:
#' * `available`: zero-arg predicate, is the engine usable here?
#' * `requirement`: what to install when it is not
#' * `what`: the inputs it analyzes, for error messages
#' * `code_label`: what the pipeline compiles to, for `show_sql` output
#'   and engine-mismatch errors
#' * `supports`: `engine =` values accepted besides `"auto"`
#' * `engine_errors`: message per rejected `engine =` value
#' * `no_fallback`: sentence appended when an `"auto"` walk hits an
#'   unsupported construct — unlike dbplyr, these engines have nowhere
#'   to fall back to
#' * `extract`: `function(x, include_indirect)` returning lineage_data
#'
#' A function rather than a top-level constant so entries can reference
#' engine functions regardless of file collation order.
#' @noRd
lineage_native_engines <- function() {
  list(
    dtplyr = list(
      available = dtplyr_engine_available,
      requirement = "dtplyr (>= 1.3.1)",
      what = "dtplyr (data.table) pipelines",
      code_label = "data.table code",
      supports = "r",
      engine_errors = list(
        sqlglot = paste0(
          "The sqlglot engine analyzes SQL, but dtplyr pipelines compile ",
          "to data.table code, not SQL. Use engine = \"auto\" or \"r\" to ",
          "walk the step tree directly."
        )
      ),
      no_fallback = paste0(
        "dtplyr pipelines compile to data.table code, not SQL, so the ",
        "sqlglot engine cannot take over; rewrite the unsupported verb ",
        "or extract lineage from an upstream step."
      ),
      extract = extract_lineage_from_dtplyr
    ),
    duckplyr = list(
      available = duckplyr_engine_available,
      requirement = paste0(
        "duckplyr (>= 1.0.0) and a duckdb build exposing the ",
        "relational API"
      ),
      what = "duckplyr pipelines",
      code_label = "duckdb SQL",
      supports = "sqlglot",
      engine_errors = list(
        r = paste0(
          "engine = \"r\" walks a lazy query tree in R, but the duckdb ",
          "relation behind a duckplyr frame is not inspectable from R. ",
          "duckplyr lineage renders the relation to SQL for the sqlglot ",
          "engine; use engine = \"auto\" or \"sqlglot\"."
        )
      ),
      no_fallback = paste0(
        "The duckdb relation could not be analyzed, and duckplyr ",
        "frames have no further fallback."
      ),
      extract = extract_lineage_from_duckplyr
    ),
    arrow = list(
      available = arrow_engine_available,
      requirement = "arrow (>= 17.0.0)",
      what = "arrow (Acero) pipelines",
      code_label = "an Acero query plan",
      supports = "r",
      engine_errors = list(
        sqlglot = paste0(
          "The sqlglot engine analyzes SQL, but arrow pipelines compile ",
          "to Acero query plans, not SQL. Use engine = \"auto\" or ",
          "\"r\" to walk the query directly."
        )
      ),
      no_fallback = paste0(
        "arrow pipelines compile to Acero query plans, not SQL, so the ",
        "sqlglot engine cannot take over; rewrite the unsupported verb ",
        "or extract lineage from an upstream step."
      ),
      extract = extract_lineage_from_arrow
    )
  )
}

#' Run one native engine, mirroring the dbplyr/sqlglot branch behavior
#'
#' An explicit `engine =` choice lets the classed
#' `dplyneage_unsupported_lineage` condition propagate raw (matching
#' `engine = "r"` on dbplyr input); `"auto"` converts it to a hard error,
#' because no other engine can take over.
#' @noRd
extract_lineage_data_native <- function(kind, x, dialect, schema, labels,
                                        show_sql, engine,
                                        include_indirect = FALSE) {
  eng <- lineage_native_engines()[[kind]]
  if (is.null(eng)) {
    stop(
      "Lineage extraction for ", kind, " pipelines is not implemented yet.",
      call. = FALSE
    )
  }
  if (engine != "auto" && !engine %in% eng$supports) {
    stop(eng$engine_errors[[engine]], call. = FALSE)
  }
  if (!eng$available()) {
    stop(
      "Analyzing ", eng$what, " requires ", eng$requirement, ".",
      call. = FALSE
    )
  }
  labels <- normalize_labels(labels)

  extract <- function() {
    eng$extract(x, include_indirect = include_indirect, schema = schema)
  }
  lineage_data <- if (engine == "auto") {
    tryCatch(
      extract(),
      dplyneage_unsupported_lineage = function(cnd) {
        stop(conditionMessage(cnd), " ", eng$no_fallback, call. = FALSE)
      }
    )
  } else {
    extract()
  }

  # A user-supplied dialect is recorded in the metadata as given; the
  # engine's own sentinel is only a default
  if (!is.null(dialect)) {
    lineage_data$dialect <- dialect
  }
  if (show_sql) {
    show_analyzed_sql(lineage_data$sql, what = eng$code_label)
  }
  finalize_lineage_data(
    lineage_data,
    labels = labels, schema = schema, con = NULL,
    dialect = lineage_data$dialect, namespace = NULL
  )
}
