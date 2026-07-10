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
#' With `include_indirect = TRUE` the walk also collects the columns used
#' in `filter()`, join keys, `group_by()`, and `arrange()` — the ones that
#' shape the result without appearing in it — and returns them as
#' `indirect`: a list of `list(table, column_name, kind)` where `kind` is
#' one of `"filter"`, `"join"`, `"group_by"`, `"sort"`.
#'
#' @param tbl A dbplyr lazy table (`tbl_lazy`)
#' @param dialect Dialect label recorded in the result metadata
#' @param include_indirect Also collect filter/join/group/sort columns?
#' @return List containing tables, columns, sql, dialect, and engine
#' @noRd
extract_lineage_from_tbl <- function(tbl, dialect = "duckdb",
                                     include_indirect = FALSE) {
  con <- dbplyr::remote_con(tbl)
  collector <- NULL
  if (include_indirect) {
    collector <- new.env(parent = emptyenv())
    collector$sources <- list()
  }
  cols <- lineage_walk(tbl$lazy_query, con, collector)

  columns <- vector("list", length(cols))
  for (i in seq_along(cols)) {
    columns[[i]] <- list(
      output_name = names(cols)[[i]],
      expression = cols[[i]]$expression,
      type = cols[[i]]$type,
      sources = cols[[i]]$sources
    )
  }

  table_names <- unique(unlist(lapply(cols, function(col) {
    vapply(col$sources, function(s) s$table, character(1))
  })))
  tables <- lapply(table_names, function(nm) list(name = nm))

  out <- list(
    tables = tables,
    columns = columns,
    sql = as.character(dbplyr::sql_render(tbl)),
    dialect = dialect,
    engine = "r"
  )
  if (include_indirect) {
    out$indirect <- dedupe_indirect(collector$sources)
  }
  out
}

#' Record indirect sources during a walk
#'
#' Resolves column names against the inner node's column map so the
#' recorded sources point at base tables, like direct sources do. No-op
#' when no collector is active, so the default walk pays nothing.
#'
#' @param collector Environment with a `sources` list, or NULL
#' @param kind One of "filter", "join", "group_by", "sort"
#' @param vars Character vector of column names used indirectly
#' @param inner Column map of the node the names resolve against
#' @noRd
note_indirect <- function(collector, kind, vars, inner) {
  if (is.null(collector)) {
    return(invisible(NULL))
  }
  for (v in intersect(vars, names(inner))) {
    for (s in inner[[v]]$sources) {
      collector$sources[[length(collector$sources) + 1]] <-
        list(table = s$table, column_name = s$column_name, kind = kind)
    }
  }
  invisible(NULL)
}

#' Variables referenced by a list of expressions (quosures work too)
#' @noRd
all_expr_vars <- function(exprs) {
  unique(unlist(lapply(exprs, all.vars)))
}

#' Drop duplicate (table, column, kind) triples
#' @noRd
dedupe_indirect <- function(sources) {
  if (length(sources) == 0) {
    return(list())
  }
  keys <- vapply(
    sources,
    function(s) paste(s$table, s$column_name, s$kind, sep = "\r"),
    character(1)
  )
  sources[!duplicated(keys)]
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
#' @param collector Optional environment accumulating indirect sources
#'   (see `note_indirect()`); NULL disables collection
#' @noRd
lineage_walk <- function(qry, con, collector = NULL) {
  UseMethod("lineage_walk")
}

#' @exportS3Method
lineage_walk.default <- function(qry, con, collector = NULL) {
  unsupported_lineage(paste0("query nodes of class <", class(qry)[[1]], ">"))
}

# Covers lazy_base_local_query (lazy_frame/memdb: path in $name) and
# lazy_base_remote_query (real tbl(): path in $x, no $name field)
#' @exportS3Method
lineage_walk.lazy_base_query <- function(qry, con, collector = NULL) {
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
    list(
      expression = v,
      type = "identity",
      sources = list(list(table = table, column_name = v))
    )
  })
  names(cols) <- qry$vars
  cols
}

# Aggregate translations dbplyr supports; used only to classify lineage
# edges for styling, so the list need not be exhaustive
r_aggregate_funs <- c(
  "sum", "min", "max", "mean", "median", "sd", "var", "n", "n_distinct",
  "count", "first", "last", "any", "all", "quantile", "str_flatten"
)

#' Classify a non-passthrough select expression for edge styling
#' @noRd
classify_r_expression <- function(e) {
  if (any(all.names(e) %in% r_aggregate_funs)) "aggregation" else "transformation"
}

# select/rename/mutate/transmute/filter/arrange/distinct/head/summarise.
# where/group_by/order_by contribute sources only when a collector is
# active; across() arrives pre-expanded; chained mutates arrive as nested
# selects.
#' @exportS3Method
lineage_walk.lazy_select_query <- function(qry, con, collector = NULL) {
  inner <- lineage_walk(qry$x, con, collector)
  note_indirect(collector, "filter", all_expr_vars(qry$where), inner)
  note_indirect(collector, "filter", all_expr_vars(qry$having), inner)
  note_indirect(collector, "group_by", all_expr_vars(qry$group_by), inner)
  note_indirect(collector, "sort", all_expr_vars(qry$order_by), inner)
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
    # A plain (possibly renamed) passthrough keeps the inner column's
    # expression and classification
    if (is.symbol(e) && as.character(e) %in% names(inner)) {
      cols[[i]] <- inner[[as.character(e)]]
      next
    }
    vars <- intersect(all.vars(e), names(inner))
    cols[[i]] <- list(
      expression = deparse1(e),
      type = classify_r_expression(e),
      sources = combine_sources(lapply(vars, function(v) inner[[v]]$sources))
    )
  }
  cols
}

# left/inner/cross joins, flattened n-ary: $vars maps each output column
# to (table index, column) where index 1 is $x and 2.. are $joins$table
#' @exportS3Method
lineage_walk.lazy_multi_join_query <- function(qry, con, collector = NULL) {
  tables <- c(
    list(lineage_walk(qry$x, con, collector)),
    lapply(qry$joins$table, lineage_walk, con = con, collector = collector)
  )
  if (!is.null(collector)) {
    for (j in seq_len(nrow(qry$joins))) {
      by <- qry$joins$by[[j]]
      x_ids <- qry$joins$by_x_table_id[[j]]
      for (k in seq_along(by$x)) {
        xt <- if (length(x_ids) >= k) x_ids[[k]] else 1L
        note_indirect(collector, "join", by$x[[k]], tables[[xt]])
        note_indirect(collector, "join", by$y[[k]], tables[[j + 1L]])
      }
    }
  }
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
lineage_walk.lazy_rf_join_query <- function(qry, con, collector = NULL) {
  xm <- lineage_walk(qry$x, con, collector)
  ym <- lineage_walk(qry$y, con, collector)
  note_indirect(collector, "join", qry$by$x, xm)
  note_indirect(collector, "join", qry$by$y, ym)
  vars <- qry$vars
  cols <- vector("list", nrow(vars))
  names(cols) <- vars$name
  for (i in seq_len(nrow(vars))) {
    parts <- list()
    if (!is.na(vars$x[[i]])) parts <- c(parts, list(xm[[vars$x[[i]]]]))
    if (!is.na(vars$y[[i]])) parts <- c(parts, list(ym[[vars$y[[i]]]]))
    if (length(parts) == 1) {
      cols[[i]] <- parts[[1]]
    } else {
      cols[[i]] <- list(
        expression = paste0(
          "coalesce(", vars$x[[i]], ", ", vars$y[[i]], ")"
        ),
        type = "transformation",
        sources = combine_sources(lapply(parts, function(p) p$sources))
      )
    }
  }
  cols
}

# semi/anti joins: y only filters rows, all columns come from x. The
# match keys on both sides count as indirect join columns; y is only
# walked when collecting, since it contributes no direct lineage.
#' @exportS3Method
lineage_walk.lazy_semi_join_query <- function(qry, con, collector = NULL) {
  inner <- lineage_walk(qry$x, con, collector)
  if (!is.null(collector)) {
    note_indirect(collector, "join", qry$by$x, inner)
    note_indirect(collector, "join", qry$by$y, lineage_walk(qry$y, con, collector))
  }
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
lineage_walk.lazy_union_query <- function(qry, con, collector = NULL) {
  cols <- lineage_walk(qry$x, con, collector)
  for (branch in qry$unions$table) {
    cols <- merge_column_maps(
      cols,
      lineage_walk(branch$lazy_query, con, collector)
    )
  }
  cols
}

# setdiff/intersect: like union, both sides contribute sources
#' @exportS3Method
lineage_walk.lazy_set_op_query <- function(qry, con, collector = NULL) {
  merge_column_maps(
    lineage_walk(qry$x, con, collector),
    lineage_walk(qry$y, con, collector)
  )
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
