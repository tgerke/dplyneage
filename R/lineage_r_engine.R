# Pure-R lineage engine: walks dbplyr's lazy query tree instead of
# rendering SQL and parsing it with sqlglot. The tree records exact column
# provenance, so no Python is needed. Emits the same lineage_data shape as
# extract_lineage_from_sql() so convert_lineage_to_graph() is shared.
#
# lazy_query internals are not exported dbplyr API; every structure handled
# here was verified against dbplyr 2.5+/2.6 and is exercised by
# test-r-engine.R so upstream changes fail loudly. Unknown node classes
# signal a classed condition that extract_lineage() can catch to fall back
# to sqlglot.

#' Is the pure-R lineage engine usable?
#'
#' Requires dbplyr >= 2.5.0: that release exported `table_path_name()` and
#' has the flattened join query structures the walker relies on.
#'
#' @return `TRUE` or `FALSE`
#' @noRd
r_engine_available <- function() {
  requireNamespace("dbplyr", quietly = TRUE) &&
    utils::packageVersion("dbplyr") >= "2.5.0"
}

#' Signal that a query uses a construct the R engine cannot trace
#'
#' Classed so callers can `tryCatch(..., dplyneage_unsupported_lineage = )`
#' and fall back to the sqlglot engine.
#'
#' @param what Description of the unsupported construct
#' @noRd
unsupported_lineage <- function(what) {
  stop(errorCondition(
    paste0("The pure-R lineage engine does not support ", what, "."),
    class = "dplyneage_unsupported_lineage"
  ))
}

#' Extract lineage from a dbplyr lazy table without Python
#'
#' Walks the table's lazy query tree and returns the same lineage_data
#' list shape as [extract_lineage_from_sql()]: `tables`, `columns` (each
#' `list(output_name, expression, sources)`), `sql`, `dialect`, plus
#' `engine = "r"`. Only select-list lineage creates sources — columns used
#' solely in `filter()`, join conditions, or `arrange()` do not, matching
#' sqlglot's lineage semantics.
#'
#' @param tbl A dbplyr lazy table (`tbl_lazy`)
#' @param dialect Dialect label recorded in the result metadata
#' @return List containing tables, columns, sql, dialect, and engine
#' @noRd
extract_lineage_from_tbl <- function(tbl, dialect = "duckdb") {
  con <- dbplyr::remote_con(tbl)
  cols <- lineage_walk(tbl$lazy_query, con)

  columns <- vector("list", length(cols))
  for (i in seq_along(cols)) {
    columns[[i]] <- list(
      output_name = names(cols)[[i]],
      expression = cols[[i]]$expression,
      sources = cols[[i]]$sources
    )
  }

  table_names <- unique(unlist(lapply(cols, function(col) {
    vapply(col$sources, function(s) s$table, character(1))
  })))
  tables <- lapply(table_names, function(nm) list(name = nm))

  list(
    tables = tables,
    columns = columns,
    sql = as.character(dbplyr::sql_render(tbl)),
    dialect = dialect,
    engine = "r"
  )
}

#' Walk a lazy query node
#'
#' Each method returns a named list, one element per visible column in
#' node order: `list(expression = <chr>, sources = list(list(table = ,
#' column_name = )))`, with sources resolved all the way down to base
#' tables.
#'
#' @param qry A dbplyr `lazy_query` node
#' @param con The remote connection, used to unquote table paths
#' @noRd
lineage_walk <- function(qry, con) {
  UseMethod("lineage_walk")
}

#' @exportS3Method
lineage_walk.default <- function(qry, con) {
  unsupported_lineage(paste0("query nodes of class <", class(qry)[[1]], ">"))
}

# Covers lazy_base_local_query (lazy_frame/memdb: path in $name) and
# lazy_base_remote_query (real tbl(): path in $x, no $name field)
#' @exportS3Method
lineage_walk.lazy_base_query <- function(qry, con) {
  path <- if (is.null(qry$name)) qry$x else qry$name
  if (inherits(path, "sql")) {
    unsupported_lineage("tables defined by raw SQL (`tbl(con, sql(...))`)")
  }
  # Keep schema/catalog qualifiers so same-named tables in different
  # schemas stay distinct nodes (matches the sqlglot engine's naming)
  table <- paste(
    unlist(dbplyr::table_path_components(path, con)),
    collapse = "."
  )
  cols <- lapply(qry$vars, function(v) {
    list(expression = v, sources = list(list(table = table, column_name = v)))
  })
  names(cols) <- qry$vars
  cols
}

# select/rename/mutate/transmute/filter/arrange/distinct/head/summarise.
# where/group_by/order_by don't contribute sources; across() arrives
# pre-expanded; chained mutates arrive as nested selects.
#' @exportS3Method
lineage_walk.lazy_select_query <- function(qry, con) {
  inner <- lineage_walk(qry$x, con)
  sel <- qry$select
  cols <- vector("list", nrow(sel))
  names(cols) <- sel$name
  for (i in seq_len(nrow(sel))) {
    e <- sel$expr[[i]]
    if (inherits(e, "sql")) {
      unsupported_lineage(
        paste0("raw SQL in expressions (`", sel$name[[i]], " = sql(...)`)")
      )
    }
    vars <- intersect(all.vars(e), names(inner))
    cols[[i]] <- list(
      expression = deparse1(e),
      sources = combine_sources(lapply(vars, function(v) inner[[v]]$sources))
    )
  }
  cols
}

# left/inner/cross joins, flattened n-ary: $vars maps each output column
# to (table index, column) where index 1 is $x and 2.. are $joins$table
#' @exportS3Method
lineage_walk.lazy_multi_join_query <- function(qry, con) {
  tables <- c(
    list(lineage_walk(qry$x, con)),
    lapply(qry$joins$table, lineage_walk, con = con)
  )
  vars <- qry$vars
  cols <- vector("list", nrow(vars))
  names(cols) <- vars$name
  for (i in seq_len(nrow(vars))) {
    cols[[i]] <- tables[[vars$table[[i]]]][[vars$var[[i]]]]
  }
  cols
}

# right/full joins: $vars has per-side column names; full-join key columns
# are coalesced from both sides, so both count as sources
#' @exportS3Method
lineage_walk.lazy_rf_join_query <- function(qry, con) {
  xm <- lineage_walk(qry$x, con)
  ym <- lineage_walk(qry$y, con)
  vars <- qry$vars
  cols <- vector("list", nrow(vars))
  names(cols) <- vars$name
  for (i in seq_len(nrow(vars))) {
    parts <- list()
    if (!is.na(vars$x[[i]])) parts <- c(parts, list(xm[[vars$x[[i]]]]))
    if (!is.na(vars$y[[i]])) parts <- c(parts, list(ym[[vars$y[[i]]]]))
    cols[[i]] <- list(
      expression = if (length(parts) == 1) parts[[1]]$expression else vars$name[[i]],
      sources = combine_sources(lapply(parts, function(p) p$sources))
    )
  }
  cols
}

# semi/anti joins: y only filters rows, all columns come from x
#' @exportS3Method
lineage_walk.lazy_semi_join_query <- function(qry, con) {
  inner <- lineage_walk(qry$x, con)
  vars <- qry$vars
  cols <- vector("list", nrow(vars))
  names(cols) <- vars$name
  for (i in seq_len(nrow(vars))) {
    cols[[i]] <- inner[[vars$var[[i]]]]
  }
  cols
}

# union/union_all, n-ary: $unions$table holds tbl_lazy objects (not
# lazy_query nodes); every branch contributes sources to each column
#' @exportS3Method
lineage_walk.lazy_union_query <- function(qry, con) {
  cols <- lineage_walk(qry$x, con)
  for (branch in qry$unions$table) {
    cols <- merge_column_maps(cols, lineage_walk(branch$lazy_query, con))
  }
  cols
}

# setdiff/intersect: like union, both sides contribute sources
#' @exportS3Method
lineage_walk.lazy_set_op_query <- function(qry, con) {
  merge_column_maps(lineage_walk(qry$x, con), lineage_walk(qry$y, con))
}

#' Merge two column maps from set-operation branches, unioning sources
#' @noRd
merge_column_maps <- function(x, y) {
  for (nm in names(y)) {
    if (nm %in% names(x)) {
      x[[nm]]$sources <- combine_sources(list(x[[nm]]$sources, y[[nm]]$sources))
    } else {
      x[[nm]] <- y[[nm]]
    }
  }
  x
}

#' Flatten a list of source lists, dropping duplicate (table, column) pairs
#' @noRd
combine_sources <- function(source_lists) {
  sources <- unlist(source_lists, recursive = FALSE)
  if (length(sources) == 0) {
    return(list())
  }
  keys <- vapply(
    sources,
    function(s) paste0(s$table, ".", s$column_name),
    character(1)
  )
  sources[!duplicated(keys)]
}
