# duckplyr lineage engine. A duckplyr_df's lazy relational tree lives
# behind an ALTREP data frame as an opaque duckdb C++ relation — there
# is no S3 tree to walk, so no pure-R path exists. Instead the relation
# is rendered to duckdb SQL, rewritten into a form sqlglot can bind
# without a live database, and analyzed by the existing sqlglot engine:
#
# * in-memory scans render as r_dataframe_scan(0x...) pointers, replaced
#   by synthesized table names (df, or df_1..df_n) by first appearance;
#   the same pointer always gets the same name, so a frame joined or
#   unioned with itself stays one node
# * file readers (read_csv_auto('...'), read_parquet('...')) become
#   synthesized identifiers too — a path used directly as a quoted table
#   name breaks sqlglot's schema binding, because schema keys are split
#   on dots — and are renamed back to the real path in the result; their
#   DESCRIBE schema feeds both column binding and column_types
# * (SELECT * FROM <ident>) AS alias wrappers collapse so references
#   bind to the named tables, and pointer-derived dataframe_N_N aliases
#   are normalized to q1, q2, ... so the recorded SQL is deterministic
#   across sessions
# * duckplyr's ___*_na aggregate macros are renamed to the standard
#   aggregates (___sum_na -> sum, ___mean_na -> avg, n() -> count(*))
#   so sqlglot's AggFunc classification fires
#
# Everything here was verified against duckplyr 1.2.1 / duckdb 1.5.1;
# rel_from_altrep_df() and rapi_rel_to_sql() are unexported duckdb API,
# so duckdb_rel_api() feature-detects them at runtime and the engine
# degrades to the classed condition when they are missing. Verbs
# duckplyr cannot translate fall back to eager dplyr upstream of us and
# return plain tibbles, so they never reach this engine — the resolver's
# data-frame error covers them.
#
# Known shape gap, pinned by tests: any verb after a projection wraps it
# in SELECT *, which re-classifies inner computed columns as identity
# (their sources stay exact). Pre-existing sqlglot behavior for nested
# SQL, not specific to this engine.

#' Is the duckplyr lineage engine usable?
#' @noRd
duckplyr_engine_available <- function() {
  requireNamespace("duckplyr", quietly = TRUE) &&
    utils::packageVersion("duckplyr") >= "1.0.0" &&
    !is.null(duckdb_rel_api())
}

#' Feature-detected accessors for duckdb's relational internals
#'
#' Unexported duckdb API, deliberately: the relation behind an ALTREP
#' frame is only reachable this way. Existence and signature are checked
#' so a future duckdb that renames them turns into a clean unavailable
#' state instead of an error mid-extraction.
#' @noRd
duckdb_rel_api <- function() {
  if (!requireNamespace("duckdb", quietly = TRUE)) {
    return(NULL)
  }
  ns <- asNamespace("duckdb")
  needed <- c("rel_from_altrep_df", "rapi_rel_to_sql")
  if (!all(vapply(needed, exists, logical(1), envir = ns, inherits = FALSE))) {
    return(NULL)
  }
  from_df <- get("rel_from_altrep_df", envir = ns)
  if (!all(c("strict", "allow_materialized") %in% names(formals(from_df)))) {
    return(NULL)
  }
  list(
    rel_from_altrep_df = from_df,
    rel_to_sql = get("rapi_rel_to_sql", envir = ns)
  )
}

#' Extract lineage from a duckplyr frame via its duckdb relation
#'
#' Returns lineage_data with `engine = "duckplyr"`, `dialect = "duckdb"`,
#' and the rewritten SQL as the recorded query text. `schema` is the
#' user's `schema =` argument; it wins over harvested file schemas and
#' the synthesized retry schema.
#' @noRd
extract_lineage_from_duckplyr <- function(x, include_indirect = FALSE,
                                          schema = NULL) {
  if (!has_sqlglot()) {
    stop(
      "duckplyr lineage renders the frame's duckdb relation to SQL and ",
      "analyzes it with the sqlglot engine; install the 'reticulate' ",
      "package (sqlglot itself is then provisioned automatically). ",
      "Unlike dbplyr pipelines there is no pure-R path: duckdb's ",
      "relation tree is not inspectable from R.",
      call. = FALSE
    )
  }
  api <- duckdb_rel_api()
  if (is.null(api)) {
    unsupported_lineage(
      "this duckdb version (its relational API is missing or changed)"
    )
  }
  rel <- api$rel_from_altrep_df(x, strict = FALSE, allow_materialized = TRUE)
  if (is.null(rel)) {
    stop(
      "The duckdb relation behind this duckplyr frame is no longer ",
      "available, so there is no query tree to analyze. Re-create the ",
      "frame with duckplyr verbs that stay lazy and extract lineage ",
      "before anything rebuilds it.",
      call. = FALSE
    )
  }

  rw <- rewrite_duckplyr_sql(api$rel_to_sql(rel))
  harvested <- describe_duckplyr_schemas(rw)
  schema_full <- merge_schemas(harvested$schema, schema)

  m <- lineage_module()
  result <- m$extract_lineage(
    rw$sql,
    dialect = "duckdb",
    schema = if (length(schema_full) > 0) schema_full else NULL,
    include_indirect = include_indirect
  )
  # A star that reaches a nameless in-memory scan cannot expand without
  # a schema and yields zero columns (filter/arrange/limit-only, semi/
  # anti joins, set ops of raw frames). Those pipelines keep the frame's
  # own columns, so retry once with names(x) for every scan.
  if (length(result$columns) == 0 && length(rw$scans) > 0) {
    synthesized <- stats::setNames(
      rep(list(names(x)), length(rw$scans)),
      rw$scans
    )
    result <- m$extract_lineage(
      rw$sql,
      dialect = "duckdb",
      schema = merge_schemas(synthesized, schema_full),
      include_indirect = include_indirect
    )
  }
  for (w in result$warnings) {
    warning(w, call. = FALSE)
  }
  result <- restore_table_case(result, rw$files)

  out <- list(
    tables = result$tables,
    columns = result$columns,
    sql = rw$sql,
    dialect = "duckdb",
    engine = "duckplyr",
    namespace = "duckdb"
  )
  if (length(harvested$column_types) > 0) {
    out$column_types <- harvested$column_types
  }
  if (include_indirect) {
    out$indirect <- strip_join_suffixes(
      result$indirect %||% list(),
      result$columns
    )
  }
  out
}

#' A word not already used in the SQL text and not already taken
#' @noRd
fresh_ident <- function(base, sql, taken) {
  nm <- base
  k <- 1L
  while (grepl(paste0("\\b", nm, "\\b"), sql) || nm %in% taken) {
    k <- k + 1L
    nm <- paste0(base, "_", k)
  }
  nm
}

#' Rewrite duckdb relation SQL into a sqlglot-bindable form
#'
#' Returns `sql` plus `scans` (the synthesized in-memory table names)
#' and `files` (each `list(path, call)` for schema harvesting).
#' @noRd
rewrite_duckplyr_sql <- function(sql) {
  # In-memory scans: one synthesized name per unique pointer
  ptrs <- unique(unlist(regmatches(
    sql,
    gregexpr("r_dataframe_scan\\(0x[0-9a-fA-F]+\\)", sql)
  )))
  scans <- character()
  for (k in seq_along(ptrs)) {
    base <- if (length(ptrs) == 1) "df" else paste0("df_", k)
    nm <- fresh_ident(base, sql, scans)
    sql <- gsub(ptrs[[k]], nm, sql, fixed = TRUE)
    scans <- c(scans, nm)
  }

  # File readers: a synthesized identifier stands in for the path (the
  # path itself cannot be a table name — sqlglot splits schema keys on
  # dots); restore_table_case() renames results back to the real path
  files <- list()
  reader_calls <- unique(unlist(regmatches(
    sql,
    gregexpr("read_[a-z_]+\\(\\s*'([^']+)'[^)]*\\)", sql)
  )))
  for (call in reader_calls) {
    path <- sub("^read_[a-z_]+\\(\\s*'([^']+)'.*$", "\\1", call)
    base <- gsub(
      "[^a-z0-9]+", "_",
      tolower(tools::file_path_sans_ext(basename(path)))
    )
    base <- sub("^_+", "", base)
    if (!grepl("^[a-z]", base)) {
      base <- paste0("file_", base)
    }
    nm <- fresh_ident(base, sql, c(scans, vapply(files, `[[`, "", "name")))
    sql <- gsub(call, nm, sql, fixed = TRUE)
    files[[length(files) + 1]] <- list(path = path, call = call, name = nm)
  }

  # Collapse (SELECT * FROM <ident>) AS alias so references bind to the
  # named table directly
  sql <- gsub(
    paste0(
      "\\(SELECT \\* FROM ([A-Za-z_][A-Za-z0-9_]*|\"[^\"]+\")\\)",
      " AS ([A-Za-z_][A-Za-z0-9_]*)"
    ),
    "\\1 AS \\2",
    sql
  )

  # Pointer-derived aliases vary per session; normalize them so the
  # recorded SQL (and lineage_json diffs) stay deterministic
  alias_tokens <- unique(unlist(regmatches(
    sql,
    gregexpr("\\bdataframe_[0-9]+_[0-9]+\\b", sql)
  )))
  taken <- scans
  for (tok in alias_tokens) {
    nm <- fresh_ident(paste0("q", match(tok, alias_tokens)), sql, taken)
    sql <- gsub(tok, nm, sql, fixed = TRUE)
    taken <- c(taken, nm)
  }

  # Aggregate macro renames, so sqlglot's AggFunc classification fires.
  # n_distinct loses its DISTINCT (count(x)) — classification and
  # sources are unaffected
  sql <- gsub("___n_distinct(_na)?\\(", "count(", sql)
  sql <- gsub("___mean_na\\(", "avg(", sql)
  sql <- gsub("___sd_na\\(", "stddev(", sql)
  sql <- gsub("___var_na\\(", "var_samp(", sql)
  sql <- gsub("___any_na\\(", "bool_or(", sql)
  sql <- gsub("___all_na\\(", "bool_and(", sql)
  sql <- gsub(
    "___(sum|min|max|median|first|last|product|mode)_na\\(",
    "\\1(",
    sql
  )
  sql <- gsub("___coalesce\\(", "coalesce(", sql)
  sql <- gsub("\\bn\\(\\)", "count(*)", sql)

  list(sql = sql, scans = scans, files = files)
}

#' Later schemas win per table name
#' @noRd
merge_schemas <- function(...) {
  out <- list()
  for (s in list(...)) {
    for (nm in names(s %||% list())) {
      out[[nm]] <- s[[nm]]
    }
  }
  out
}

#' DESCRIBE file scans and compute() temp tables on duckplyr's connection
#'
#' Returns `schema` (table -> bare column-name vector: sqlglot lineage
#' loses source attribution when handed col-to-type dicts, so types
#' never go into the binding schema) and the typed `column_types`. The
#' schema is keyed by the synthesized in-SQL identifier; `column_types`
#' by the real path, which is what the lineage carries after
#' restore_table_case(). Everything is tryCatch-wrapped: schema
#' harvesting must never break extraction.
#' @noRd
describe_duckplyr_schemas <- function(rw) {
  out <- list(schema = list(), column_types = list())
  targets <- lapply(rw$files, function(f) {
    list(name = f$path, key = f$name, from = f$call)
  })
  for (tmp in unique(unlist(regmatches(
    rw$sql,
    gregexpr("\\bduckplyr_[A-Za-z0-9]+\\b", rw$sql)
  )))) {
    # compute() temp tables are unquoted, so sqlglot lower-cases them in
    # the result; key the types the same way so they reach the node
    targets[[length(targets) + 1]] <- list(
      name = tolower(tmp), key = tmp, from = tmp
    )
  }
  if (length(targets) == 0) {
    return(out)
  }
  con <- tryCatch(
    get("get_default_duckdb_connection", envir = asNamespace("duckplyr"))(),
    error = function(e) NULL
  )
  if (is.null(con)) {
    return(out)
  }
  for (target in targets) {
    described <- tryCatch(
      DBI::dbGetQuery(
        con,
        paste0("DESCRIBE SELECT * FROM ", target$from)
      ),
      error = function(e) NULL
    )
    if (is.null(described) || nrow(described) == 0) {
      next
    }
    out$schema[[target$key]] <- described$column_name
    out$column_types[[target$name]] <- stats::setNames(
      described$column_type,
      described$column_name
    )
  }
  out
}

#' Rename synthesized file-scan identifiers back to their real paths
#' @noRd
restore_table_case <- function(result, files) {
  if (length(files) == 0) {
    return(result)
  }
  fix <- stats::setNames(
    vapply(files, function(f) f$path, character(1)),
    vapply(files, function(f) f$name, character(1))
  )
  rename <- function(nm) {
    if (is.character(nm) && length(nm) == 1 && nm %in% names(fix)) {
      fix[[nm]]
    } else {
      nm
    }
  }
  result$tables <- lapply(result$tables, function(tbl) {
    tbl$name <- rename(tbl$name)
    tbl
  })
  result$columns <- lapply(result$columns, function(col) {
    col$sources <- lapply(col$sources, function(s) {
      s$table <- rename(s$table)
      s
    })
    col
  })
  result$indirect <- lapply(result$indirect %||% list(), function(s) {
    s$table <- rename(s$table)
    s
  })
  result
}

#' Strip duckplyr's internal _x/_y join-key suffixes from indirect refs
#'
#' The join SQL renames key columns (g becomes g_x/g_y inside the join),
#' so indirect join entries surface suffixed names that exist in no real
#' table. Strip the suffix only when the stripped name is a known direct
#' source of that table and the suffixed one is not — a real column
#' named g_x stays untouched. Dedupes afterwards.
#' @noRd
strip_join_suffixes <- function(indirect, columns) {
  if (length(indirect) == 0) {
    return(indirect)
  }
  direct <- unlist(lapply(columns, function(col) {
    vapply(
      col$sources,
      function(s) paste(s$table, s$column_name, sep = "\r"),
      character(1)
    )
  }))
  out <- list()
  seen <- character()
  for (s in indirect) {
    stripped <- sub("_(x|y)$", "", s$column_name)
    if (
      stripped != s$column_name &&
        paste(s$table, stripped, sep = "\r") %in% direct &&
        !paste(s$table, s$column_name, sep = "\r") %in% direct
    ) {
      s$column_name <- stripped
    }
    key <- paste(s$table, s$column_name, s$kind, sep = "\r")
    if (!key %in% seen) {
      seen <- c(seen, key)
      out[[length(out) + 1]] <- s
    }
  }
  out
}
