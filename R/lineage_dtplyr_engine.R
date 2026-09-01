# dtplyr lineage engine: walks the lazy_dt() step tree the same way the
# dbplyr engine walks lazy_query nodes, emitting the same lineage_data
# shape. dtplyr translates verbs to data.table code at step-build time,
# so expressions arrive as data.table calls (n() is .N, case_when() is
# fcase(), row_number() is seq_len(.N)) — but column references survive
# intact, so the all.vars() analysis carries over.
#
# dtplyr_step internals are not exported API; every structure handled
# here was verified against dtplyr 1.3.1: the nine step classes, the
# per-style $on orientation of step_join (left swaps parent/parent2 and
# names key columns after the y-side key; inner/right/semi/anti flip
# on$x/on$y), the positional 1:1 alignment of step_call setnames $vars
# with the parent's columns, and show_query() returning the data.table
# call. test-dtplyr-engine.R exercises all of it so upstream changes
# fail loudly, and every walker degrades to the classed
# dplyneage_unsupported_lineage condition rather than guessing.
#
# There is no OVER clause in data.table code, so the dbplyr engine's
# window rule (partition/order columns count as direct sources of a
# windowed column) has no analog here: grouped cumsum/rank columns get
# their grouping keys as indirect group_by entries only.

#' Is the dtplyr lineage engine usable?
#'
#' The floor is the version the walker's structures were verified
#' against; see the file header.
#' @noRd
dtplyr_engine_available <- function() {
  requireNamespace("dtplyr", quietly = TRUE) &&
    utils::packageVersion("dtplyr") >= "1.3.1"
}

#' Extract lineage from a dtplyr lazy_dt step tree
#'
#' Returns the same lineage_data shape as `extract_lineage_from_tbl()`,
#' with `dialect = "data.table"` and the generated data.table call in
#' the `sql` slot.
#' @noRd
extract_lineage_from_dtplyr <- function(x, include_indirect = FALSE) {
  collector <- new.env(parent = emptyenv())
  collector$labels <- list()
  if (include_indirect) {
    collector$sources <- list()
  }
  cols <- lineage_walk(x, con = NULL, collector = collector)
  assemble_lineage_data(
    cols, collector, include_indirect,
    sql = paste(deparse(dplyr::show_query(x)), collapse = "\n"),
    dialect = "data.table",
    engine = "dtplyr"
  )
}

# --- expression analysis ----------------------------------------------

# data.table spellings of aggregate calls, alongside r_aggregate_funs
dt_aggregate_names <- c(".N", "uniqueN")

#' Replace subcalls matching `test` with `value`, recursively
#' @noRd
replace_dt_calls <- function(e, test, value) {
  if (!is.call(e)) {
    return(e)
  }
  if (test(e)) {
    return(value)
  }
  for (k in seq_along(e)[-1]) {
    ek <- e[[k]]
    if (!identical(ek, quote(expr = ))) {
      e[[k]] <- replace_dt_calls(ek, test, value)
    }
  }
  e
}

#' Neutralize fcase()'s translated default arm, rep(TRUE, .N)
#'
#' case_when(..., TRUE ~ x) arrives as fcase(..., rep(TRUE, .N), x): the
#' .N there is row-count plumbing, neither an aggregate nor evidence the
#' expression depends on grouping.
#' @noRd
strip_fcase_default <- function(e) {
  replace_dt_calls(
    e,
    function(x) {
      length(x) == 3 && identical(x[[1]], as.name("rep")) &&
        isTRUE(x[[2]]) && identical(x[[3]], as.name(".N"))
    },
    TRUE
  )
}

#' Neutralize row_number()'s translation, seq_len(.N)
#'
#' Group-shaped (the numbering restarts per group) but not an aggregate.
#' @noRd
strip_row_number <- function(e) {
  replace_dt_calls(
    e,
    function(x) {
      length(x) == 2 && identical(x[[1]], as.name("seq_len")) &&
        identical(x[[2]], as.name(".N"))
    },
    as.name(".row_number.")
  )
}

#' Classify a translated data.table expression for edge styling
#' @noRd
classify_dt_expression <- function(e) {
  e <- strip_row_number(strip_fcase_default(e))
  agg <- c(r_aggregate_funs, dt_aggregate_names)
  if (any(all.names(e) %in% agg)) "aggregation" else "transformation"
}

#' Does any of these expressions depend on the grouping structure?
#'
#' Built inside the function, not at load time: this file collates
#' before lineage_r_engine.R, where r_aggregate_funs lives.
#' seq_len(.N) counts through its .N; fcase's rep(TRUE, .N) must not.
#' @noRd
dt_uses_groups <- function(exprs) {
  group_sensitive <- c(
    r_aggregate_funs, dt_aggregate_names,
    "cumsum", "cummean", "cummax", "cummin", "shift", "frank", ".I"
  )
  any(vapply(
    exprs,
    function(e) {
      !is.null(e) &&
        any(all.names(strip_fcase_default(e)) %in% group_sensitive)
    },
    logical(1)
  ))
}

#' Build one column entry from a translated expression
#'
#' A bare symbol naming an existing column is a passthrough/rename and
#' keeps the inner entry (and its classification, so identity chains
#' still propagate labels). intersect() drops .N/.I/.SD and the table's
#' own symbol from the referenced names.
#' @noRd
dt_col_entry <- function(e, inner) {
  if (is.symbol(e) && as.character(e) %in% names(inner)) {
    return(inner[[as.character(e)]])
  }
  vars <- intersect(all.vars(e), names(inner))
  list(
    expression = deparse1(e),
    type = classify_dt_expression(e),
    sources = combine_sources(lapply(vars, function(v) inner[[v]]$sources))
  )
}

#' Reorder a column map to a step's $vars, or refuse loudly
#'
#' Every step records its visible columns in $vars; a walker whose map
#' disagrees has misread the step, and wrong lineage is worse than none.
#' @noRd
dt_align_vars <- function(map, vars, step) {
  if (!all(vars %in% names(map))) {
    unsupported_lineage(
      paste0("this ", step, " step's column bookkeeping ",
             "(a dtplyr internals change?)")
    )
  }
  map[vars]
}

# --- walkers ----------------------------------------------------------

#' @exportS3Method
lineage_walk.dtplyr_step_first <- function(qry, con, collector = NULL) {
  table <- as.character(qry[["name"]])
  parent <- qry[["parent"]]
  # The source data.table still holds the original columns, so
  # haven/labelled label attributes are readable here (they survive both
  # the copy and no-copy paths of lazy_dt())
  if (!is.null(collector) && is.data.frame(parent)) {
    labs <- frame_column_labels(parent)
    if (length(labs) > 0) {
      collector$labels[[table]] <- labs
    }
  }
  cols <- lapply(qry[["vars"]], function(v) {
    list(
      expression = v,
      type = "identity",
      sources = list(list(table = table, column_name = v))
    )
  })
  names(cols) <- qry[["vars"]]
  cols
}

# group_by()/ungroup() bookkeeping: grouping is re-recorded on the
# consuming step's own $groups, so the wrapper itself is a passthrough
#' @exportS3Method
lineage_walk.dtplyr_step_group <- function(qry, con, collector = NULL) {
  lineage_walk(qry[["parent"]], con, collector)
}

# compute(): materialization point, lineage flows straight through
#' @exportS3Method
lineage_walk.dtplyr_step_assign <- function(qry, con, collector = NULL) {
  lineage_walk(qry[["parent"]], con, collector)
}

#' @exportS3Method
lineage_walk.dtplyr_step_modify <- function(qry, con, collector = NULL) {
  unsupported_lineage("group_modify() (arbitrary R functions)")
}

# mutate(): $new_vars is a named list of translated expressions,
# sequential left-to-right — later entries may reference earlier ones
#' @exportS3Method
lineage_walk.dtplyr_step_mutate <- function(qry, con, collector = NULL) {
  inner <- lineage_walk(qry[["parent"]], con, collector)
  new_vars <- qry[["new_vars"]]
  map <- inner
  for (nm in names(new_vars)) {
    e <- new_vars[[nm]]
    if (is.null(e)) {
      map[[nm]] <- NULL # mutate(x = NULL) drops the column
      next
    }
    map[[nm]] <- dt_col_entry(e, map)
  }
  groups <- qry[["groups"]]
  if (length(groups) > 0 && dt_uses_groups(new_vars)) {
    note_indirect(collector, "group_by", groups, inner)
  }
  dt_align_vars(map, qry[["vars"]], "mutate")
}

# filter/select/transmute/summarise/arrange land here; consecutive verbs
# merge, so one step may carry i, j, and groups at once
#' @exportS3Method
lineage_walk.dtplyr_step_subset <- function(qry, con, collector = NULL) {
  inner <- lineage_walk(qry[["parent"]], con, collector)
  i <- qry[["i"]]
  j <- qry[["j"]]
  groups <- qry[["groups"]]

  if (!is.null(i)) {
    note_subset_i(collector, i, inner)
  }
  if (is.null(j)) {
    return(dt_align_vars(inner, qry[["vars"]], "subset"))
  }

  if (length(groups) > 0) {
    note_indirect(collector, "group_by", groups, inner)
  }
  map <- dt_parse_j(j, inner)
  if (is.null(map)) {
    unsupported_lineage(
      paste0("this data.table j expression (`", deparse1(j), "`)")
    )
  }
  # Group keys are prepended to $vars but absent from j: identity
  # passthroughs from the inner map
  for (g in groups) {
    if (!g %in% names(map) && g %in% names(inner)) {
      map[[g]] <- inner[[g]]
    }
  }
  dt_align_vars(map, qry[["vars"]], "subset")
}

#' Record the indirect columns an i clause uses
#'
#' Three rendered shapes: order(...) from arrange(), the grouped-filter
#' pattern `TBL[, .I[cond], by = .(g)]$V1`, and a plain row condition.
#' @noRd
note_subset_i <- function(collector, i, inner) {
  if (!collecting(collector)) {
    return(invisible(NULL))
  }
  grouped <- unwrap_grouped_i(i)
  if (!is.null(grouped)) {
    note_indirect(collector, "filter", all.vars(grouped$cond), inner)
    note_indirect(collector, "group_by", grouped$by_vars, inner)
  } else if (is.call(i) && identical(i[[1]], as.name("order"))) {
    note_indirect(collector, "sort", all.vars(i), inner)
  } else {
    # intersect() inside note_indirect drops .I/.N and the table's own
    # symbol from a shape this didn't recognize
    note_indirect(collector, "filter", all.vars(i), inner)
  }
  invisible(NULL)
}

#' Unwrap the grouped-filter i pattern, or NULL if i isn't one
#' @noRd
unwrap_grouped_i <- function(i) {
  if (!(is.call(i) && length(i) == 3 && identical(i[[1]], as.name("$")))) {
    return(NULL)
  }
  inner_call <- i[[2]]
  if (
    !(is.call(inner_call) && length(inner_call) >= 4 &&
        identical(inner_call[[1]], as.name("[")))
  ) {
    return(NULL)
  }
  j <- inner_call[[4]]
  by <- inner_call[["by"]]
  if (
    is.null(by) || !(is.call(j) && length(j) == 3 &&
                       identical(j[[1]], as.name("[")) &&
                       identical(j[[2]], as.name(".I")))
  ) {
    return(NULL)
  }
  by_vars <- if (is.character(by)) by else all.vars(by)
  list(cond = j[[3]], by_vars = by_vars)
}

#' Parse a translated j expression into a column map, or NULL
#'
#' Handles the three shapes dtplyr renders: `.()`/`list()` projections,
#' `{}` blocks of sequential assignments ending in `.()`, and `:=`
#' updates (including the c("a", "b") := NULL column-drop form that
#' select() renders after joins).
#' @noRd
dt_parse_j <- function(j, inner) {
  if (!is.call(j)) {
    return(NULL)
  }
  head <- j[[1]]
  if (identical(head, as.name(".")) || identical(head, as.name("list"))) {
    return(dt_parse_j_list(j, inner))
  }
  if (identical(head, as.name("{"))) {
    map <- inner
    body <- as.list(j)[-1]
    if (length(body) == 0) {
      return(NULL)
    }
    for (stmt in body[-length(body)]) {
      if (
        is.call(stmt) && length(stmt) == 3 &&
          identical(stmt[[1]], as.name("<-")) && is.symbol(stmt[[2]])
      ) {
        map[[as.character(stmt[[2]])]] <- dt_col_entry(stmt[[3]], map)
      } else {
        return(NULL)
      }
    }
    last <- body[[length(body)]]
    if (
      is.call(last) && (identical(last[[1]], as.name(".")) ||
                          identical(last[[1]], as.name("list")))
    ) {
      return(dt_parse_j_list(last, map))
    }
    return(NULL)
  }
  if (identical(head, as.name(":="))) {
    return(dt_parse_j_assign(j, inner))
  }
  NULL
}

#' @noRd
dt_parse_j_list <- function(j, inner) {
  args <- as.list(j)[-1]
  nms <- names(args) %||% rep("", length(args))
  out <- list()
  for (k in seq_along(args)) {
    e <- args[[k]]
    nm <- nms[[k]]
    if (!nzchar(nm)) {
      if (!is.symbol(e)) {
        return(NULL)
      }
      nm <- as.character(e)
    }
    out[[nm]] <- dt_col_entry(e, inner)
  }
  out
}

#' A single string or a c("a", "b") literal, else NULL
#' @noRd
dt_chr_literal <- function(a) {
  if (is.character(a)) {
    return(a)
  }
  if (is.call(a) && identical(a[[1]], as.name("c"))) {
    parts <- as.list(a)[-1]
    if (length(parts) > 0 && all(vapply(parts, is.character, logical(1)))) {
      return(unlist(parts))
    }
  }
  NULL
}

#' @noRd
dt_parse_j_assign <- function(j, inner) {
  args <- as.list(j)[-1]
  nms <- names(args) %||% rep("", length(args))
  # `:=`(c("a", "b"), NULL): the column-drop form
  if (length(args) == 2 && !any(nzchar(nms)) && is.null(args[[2]])) {
    drop <- dt_chr_literal(args[[1]])
    if (is.null(drop)) {
      return(NULL)
    }
    return(inner[setdiff(names(inner), drop)])
  }
  map <- inner
  if (all(nzchar(nms))) {
    # `:=`(a = e1, b = e2): mutate-style updates
    for (k in seq_along(args)) {
      map[[nms[[k]]]] <- dt_col_entry(args[[k]], map)
    }
    return(map)
  }
  if (length(args) == 2 && !any(nzchar(nms))) {
    # `:=`(a, e) with a symbol or string target
    nm <- if (is.symbol(args[[1]])) {
      as.character(args[[1]])
    } else if (is.character(args[[1]]) && length(args[[1]]) == 1) {
      args[[1]]
    }
    if (is.null(nm)) {
      return(NULL)
    }
    map[[nm]] <- dt_col_entry(args[[2]], map)
    return(map)
  }
  NULL
}

# rename (setnames), relocate + join repair (setcolorder), distinct
# (unique), head/tail, slice_max/min ordering (setorder)
#' @exportS3Method
lineage_walk.dtplyr_step_call <- function(qry, con, collector = NULL) {
  inner <- lineage_walk(qry[["parent"]], con, collector)
  fun <- qry[["fun"]]
  vars <- qry[["vars"]]
  if (identical(fun, "setnames")) {
    # $vars aligns 1:1 positionally with the parent's columns, which
    # covers every rename form (by name, by position, by function)
    if (length(inner) != length(vars)) {
      unsupported_lineage(
        "this rename step's column bookkeeping (a dtplyr internals change?)"
      )
    }
    names(inner) <- vars
    return(inner)
  }
  if (identical(fun, "setcolorder")) {
    return(dt_align_vars(inner, vars, "column-order"))
  }
  if (identical(fun, "unique")) {
    by <- qry[["args"]][["by"]]
    if (is.character(by)) {
      note_indirect(collector, "filter", by, inner)
    }
    return(dt_align_vars(inner, vars, "distinct"))
  }
  if (identical(fun, "head") || identical(fun, "tail")) {
    return(dt_align_vars(inner, vars, fun))
  }
  if (identical(fun, "setorder")) {
    note_indirect(collector, "sort", all_expr_vars(qry[["args"]]), inner)
    return(dt_align_vars(inner, vars, "ordering"))
  }
  unsupported_lineage(paste0("data.table calls to ", fun, "()"))
}

# Joins. Orientation is style-specific (verified with asymmetric keys):
# left builds y[x], so parent is dplyr's y, parent2 is x, on$x/on$y hold
# the x/y key names, and key columns in $vars carry the y-side names;
# inner/right/semi/anti keep parent = x, parent2 = y but flip on (on$x
# is the y key, on$y the x key), with key columns named after x; full
# renders merge(x, y) with on unflipped and $vars already suffixed.
# Conflicted i-side columns arrive i.-prefixed; the repair steps above
# the join rename them positionally.
#' @exportS3Method
lineage_walk.dtplyr_step_join <- function(qry, con, collector = NULL) {
  style <- qry[["style"]]
  on <- qry[["on"]]
  vars <- qry[["vars"]]

  if (identical(style, "left")) {
    x_map <- lineage_walk(qry[["parent2"]], con, collector)
    y_map <- lineage_walk(qry[["parent"]], con, collector)
    x_keys <- on$x
    y_keys <- on$y
  } else if (style %in% c("inner", "right", "full", "semi", "anti")) {
    x_map <- lineage_walk(qry[["parent"]], con, collector)
    y_map <- NULL
    if (!style %in% c("semi", "anti")) {
      y_map <- lineage_walk(qry[["parent2"]], con, collector)
    }
    if (identical(style, "full")) {
      x_keys <- on$x
      y_keys <- on$y
    } else {
      x_keys <- on$y
      y_keys <- on$x
    }
  } else {
    unsupported_lineage(paste0(style, " joins"))
  }

  if (style %in% c("semi", "anti")) {
    # y only filters rows; walked just for its indirect join keys
    if (collecting(collector)) {
      note_indirect(collector, "join", x_keys, x_map)
      note_indirect(
        collector, "join", y_keys,
        lineage_walk(qry[["parent2"]], con, collector)
      )
    }
    return(dt_align_vars(x_map, vars, "join"))
  }

  note_indirect(collector, "join", x_keys, x_map)
  note_indirect(collector, "join", y_keys, y_map)

  if (identical(style, "full")) {
    # merge() output order: keys (x names), x's non-keys, y's non-keys.
    # Key columns coalesce both sides, like dbplyr's rf-join
    x_rest <- setdiff(names(x_map), x_keys)
    y_rest <- setdiff(names(y_map), y_keys)
    if (length(vars) != length(x_keys) + length(x_rest) + length(y_rest)) {
      unsupported_lineage("this full join's column bookkeeping")
    }
    cols <- vector("list", length(vars))
    names(cols) <- vars
    for (k in seq_along(x_keys)) {
      xe <- x_map[[x_keys[[k]]]]
      ye <- y_map[[y_keys[[k]]]]
      cols[[k]] <- list(
        expression = paste0("coalesce(", x_keys[[k]], ", ", y_keys[[k]], ")"),
        type = "transformation",
        sources = combine_sources(list(xe$sources, ye$sources))
      )
    }
    off <- length(x_keys)
    for (k in seq_along(x_rest)) {
      cols[[off + k]] <- x_map[[x_rest[[k]]]]
    }
    off <- off + length(x_rest)
    for (k in seq_along(y_rest)) {
      cols[[off + k]] <- y_map[[y_rest[[k]]]]
    }
    return(cols)
  }

  # left/inner/right: key columns attribute to the side dplyr keeps
  # (x, except right joins keep y), everything else resolves plain-side
  # first, then i.-stripped, then i-side
  key_names <- if (identical(style, "left")) y_keys else x_keys
  plain_map <- if (identical(style, "left")) y_map else x_map
  i_map <- if (identical(style, "left")) x_map else y_map
  cols <- vector("list", length(vars))
  names(cols) <- vars
  for (k in seq_along(vars)) {
    v <- vars[[k]]
    ki <- match(v, key_names)
    if (!is.na(ki)) {
      cols[[k]] <- if (identical(style, "right")) {
        y_map[[y_keys[[ki]]]]
      } else {
        x_map[[x_keys[[ki]]]]
      }
      next
    }
    entry <- plain_map[[v]]
    if (is.null(entry) && startsWith(v, "i.")) {
      entry <- i_map[[substring(v, 3)]]
    }
    if (is.null(entry)) {
      entry <- i_map[[v]]
    }
    if (is.null(entry)) {
      unsupported_lineage("this join's column bookkeeping")
    }
    cols[[k]] <- entry
  }
  cols
}

# union/union_all/setdiff/intersect: both branches contribute sources
#' @exportS3Method
lineage_walk.dtplyr_step_set <- function(qry, con, collector = NULL) {
  merged <- merge_column_maps(
    lineage_walk(qry[["parent"]], con, collector),
    lineage_walk(qry[["parent2"]], con, collector)
  )
  dt_align_vars(merged, qry[["vars"]], "set-operation")
}
