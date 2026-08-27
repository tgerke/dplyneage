# Programmatic access to lineage objects: print method, data frame
# accessors, diffs, and impact-analysis traversals. Everything here works
# on the extract_lineage() contract (nodes/edges/metadata), so hand-built
# node/edge lists work too.

`%||%` <- function(x, y) if (is.null(x)) y else x

#' @export
print.dplyneage_lineage <- function(x, ...) {
  ids <- vapply(x$nodes, function(n) n$id, character(1))
  types <- vapply(
    x$nodes,
    function(n) n$data$tableType %||% NA_character_,
    character(1)
  )

  cat("<dplyneage lineage>\n")
  meta <- x$metadata
  if (!is.null(meta$engine)) {
    cat("  engine: ", meta$engine, " (dialect: ", meta$dialect, ")\n", sep = "")
  }
  sources <- ids[is.na(types) | !(types %in% c("transform", "target"))]
  cat(
    "  sources: ",
    if (length(sources)) paste(sources, collapse = ", ") else "(none)",
    "\n",
    sep = ""
  )
  transforms <- ids[!is.na(types) & types == "transform"]
  if (length(transforms)) {
    cat("  transforms: ", paste(transforms, collapse = ", "), "\n", sep = "")
  }
  for (i in which(!is.na(types) & types == "target")) {
    cols <- unlist(x$nodes[[i]]$data$columns)
    cat("  ", ids[[i]], ": ", paste(cols, collapse = ", "), "\n", sep = "")
  }
  n_edges <- length(x$edges)
  cat("  ", n_edges, " column edge", if (n_edges == 1) "" else "s", "\n", sep = "")
  invisible(x)
}

#' Lineage edges as a data frame
#'
#' Flattens a lineage object's column-level edges into one row per edge,
#' for filtering, joining, and summarising with ordinary data frame tools.
#' For edges produced by [extract_lineage()], the `transformation` column
#' classifies each edge (`"identity"` for plain column passthrough,
#' `"aggregation"`, or `"transformation"`) and `expression` records the
#' output column's defining expression; both are `NA` for hand-built
#' edges. With `include_indirect = TRUE`, indirect edges are classified by
#' how the source column is used — `"filter"`, `"join"`, `"group_by"`, or
#' `"sort"` — with `NA` for `expression`.
#'
#' @param lineage The result of [extract_lineage()], or any list with
#'   `nodes` and `edges` built with [create_table_node()] and
#'   [create_column_edge()].
#' @return A data frame with columns `source_table`, `source_column`,
#'   `target_table`, `target_column`, `transformation`, and `expression`.
#' @family lineage accessors
#' @export
#' @examples
#' lineage <- list(
#'   nodes = list(
#'     create_table_node("orders", c("order_id", "amount")),
#'     create_table_node("daily_totals", "total", table_type = "target")
#'   ),
#'   edges = list(
#'     create_column_edge("orders", "amount", "daily_totals", "total")
#'   )
#' )
#' lineage_edges(lineage)
lineage_edges <- function(lineage) {
  check_lineage(lineage)
  edges <- lineage$edges
  chr <- function(f) vapply(edges, f, character(1))
  data.frame(
    source_table = chr(function(e) e$source),
    source_column = chr(function(e) e$sourceHandle),
    target_table = chr(function(e) e$target),
    target_column = chr(function(e) e$targetHandle),
    transformation = chr(function(e) e$data$transformation %||% NA_character_),
    expression = chr(function(e) e$data$expression %||% NA_character_),
    stringsAsFactors = FALSE
  )
}

#' Lineage tables as a data frame
#'
#' Summarises a lineage object's nodes: one row per table with its diagram
#' role and column count.
#'
#' @inheritParams lineage_edges
#' @return A data frame with columns `table`, `type` (`"source"`,
#'   `"transform"`, or `"target"`), and `n_columns`.
#' @family lineage accessors
#' @export
#' @examples
#' lineage <- list(
#'   nodes = list(
#'     create_table_node("orders", c("order_id", "amount")),
#'     create_table_node("daily_totals", "total", table_type = "target")
#'   ),
#'   edges = list()
#' )
#' lineage_tables(lineage)
lineage_tables <- function(lineage) {
  check_lineage(lineage)
  nodes <- lineage$nodes
  data.frame(
    table = vapply(nodes, function(n) n$id, character(1)),
    type = vapply(
      nodes,
      function(n) n$data$tableType %||% NA_character_,
      character(1)
    ),
    n_columns = vapply(
      nodes,
      function(n) length(unlist(n$data$columns)),
      integer(1)
    ),
    stringsAsFactors = FALSE
  )
}

#' Trace a column's ancestry or descendants
#'
#' `lineage_upstream()` lists every column that feeds into `column`,
#' following edges transitively; `lineage_downstream()` lists every column
#' `column` feeds into. This is the core impact-analysis question — "what
#' breaks if this column changes?" — answered directly on the lineage
#' object, without exporting to a graph tool.
#'
#' @inheritParams lineage_edges
#' @param column A `"table.column"` string identifying the column to trace
#'   from, e.g. `"output.total_spent"`.
#' @return A character vector of `"table.column"` identifiers, sorted.
#'   Empty when the column has no upstream (or downstream) connections.
#' @family lineage accessors
#' @export
#' @examples
#' lineage <- list(
#'   nodes = list(
#'     create_table_node("orders", "amount"),
#'     create_table_node("daily_totals", "total", table_type = "target")
#'   ),
#'   edges = list(
#'     create_column_edge("orders", "amount", "daily_totals", "total")
#'   )
#' )
#' lineage_upstream(lineage, "daily_totals.total")
#' lineage_downstream(lineage, "orders.amount")
lineage_upstream <- function(lineage, column) {
  traverse_lineage(lineage, column, direction = "upstream")
}

#' @rdname lineage_upstream
#' @export
lineage_downstream <- function(lineage, column) {
  traverse_lineage(lineage, column, direction = "downstream")
}

#' Everything reachable from `start` (excluded) along step_from -> step_to
#' @noRd
bfs_reachable <- function(step_from, step_to, start) {
  seen <- character()
  frontier <- start
  while (length(frontier) > 0) {
    frontier <- setdiff(unique(step_to[step_from %in% frontier]), seen)
    seen <- c(seen, frontier)
  }
  sort(seen)
}

#' @noRd
traverse_lineage <- function(lineage, column, direction) {
  check_lineage(lineage)
  edges <- lineage_edges(lineage)
  from <- paste0(edges$source_table, ".", edges$source_column)
  to <- paste0(edges$target_table, ".", edges$target_column)

  known <- unique(c(from, to, unlist(lapply(lineage$nodes, function(n) {
    paste0(n$id, ".", unlist(n$data$columns))
  }))))
  if (!is.character(column) || length(column) != 1 || !column %in% known) {
    stop(
      "`column` must be a \"table.column\" string present in the lineage",
      if (length(known)) paste0(" (e.g. \"", known[[1]], "\")"),
      ".",
      call. = FALSE
    )
  }

  if (direction == "upstream") {
    step_from <- to
    step_to <- from
  } else {
    step_from <- from
    step_to <- to
  }
  bfs_reachable(step_from, step_to, column)
}

#' Severity of changing/removing each `table.column`, judged in `old` —
#' the lineage existing consumers were built on. Breaking when the column
#' fed anything downstream, or sat on a target node (the graph cannot see
#' outside consumers of the final surface; unknown types stay cautious).
#' @noRd
change_severity <- function(old, tables, columns) {
  keys <- paste0(tables, ".", columns)
  if (length(keys) == 0) {
    return(character(0))
  }

  edges <- lineage_edges(old)
  from <- paste0(edges$source_table, ".", edges$source_column)
  to <- paste0(edges$target_table, ".", edges$target_column)
  uniq <- unique(keys)
  has_downstream <- vapply(
    uniq,
    function(key) length(bfs_reachable(from, to, key)) > 0,
    logical(1)
  )[match(keys, uniq)]

  node_types <- vapply(
    old$nodes,
    function(n) n$data$tableType %||% NA_character_,
    character(1)
  )
  names(node_types) <- vapply(old$nodes, function(n) n$id, character(1))
  type <- unname(node_types[tables])
  on_target <- is.na(type) | type == "target"

  ifelse(has_downstream | on_target, "breaking", "non-breaking")
}

#' Compare two lineage extractions
#'
#' Reports the column-level edges and table columns that changed between
#' two lineage objects — typically the same pipeline before and after an
#' edit. Edges are keyed by their endpoints, and an edge present in both
#' objects still counts as changed when its transformation classification
#' or defining expression differs: rewriting `sum(amount)` as
#' `mean(amount)` changes provenance even though the same columns stay
#' connected.
#'
#' Each change is also classified by blast radius: a `severity` column
#' on every element marks it `"breaking"` when it could invalidate
#' something built on the old lineage, `"non-breaking"` otherwise. See
#' Details for the rule.
#'
#' This makes the CI story concrete: extract lineage on both branches
#' and fail (or comment) when provenance changed, e.g.
#' `if (lineage_has_changes(lineage_diff(old, new))) stop("column
#' provenance changed")`.
#'
#' @details
#' Severity is judged against `old`, the lineage existing consumers were
#' built on. A removed or changed edge — and a removed column — is
#' `"breaking"` when its target column fed other columns downstream, or
#' belonged to a target node: target columns are the pipeline's consumed
#' surface, and the graph cannot see the dashboards and jobs reading
#' them, so changing one is assumed to break something. Nodes without a
#' declared type get the same cautious treatment. Everything else is
#' `"non-breaking"`: additions cannot invalidate an existing consumer,
#' and neither can removing an intermediate column nothing consumed.
#'
#' One caveat for hand-built lineages whose edges carry no expressions:
#' there, adding a source to an existing column shows up only in
#' `added_edges`, which is always non-breaking. Engine-extracted lineage
#' also reports the column's surviving edges in `changed_edges`, because
#' its defining expression changed, and those get the breaking check.
#'
#' @param old,new Lineage objects from [extract_lineage()] (or lists with
#'   `nodes` and `edges`), in before/after order.
#' @return A `dplyneage_lineage_diff` list with data frame elements
#'   `added_edges`, `removed_edges`, `changed_edges`, `added_columns`,
#'   and `removed_columns`, each carrying a `severity` column
#'   (`"breaking"` or `"non-breaking"`). `changed_edges` also records
#'   the old and new transformation and expression for each edge whose
#'   endpoints matched but whose definition differs. The print method
#'   summarises the changes; zero-row elements mean no change.
#'   `lineage_has_changes()` returns `TRUE` when any element has rows.
#' @family lineage accessors
#' @export
#' @examples
#' old <- list(
#'   nodes = list(
#'     create_table_node("orders", "amount"),
#'     create_table_node("out", "total", table_type = "target")
#'   ),
#'   edges = list(create_column_edge("orders", "amount", "out", "total"))
#' )
#' new <- list(
#'   nodes = list(
#'     create_table_node("orders", c("amount", "tax")),
#'     create_table_node("out", "total", table_type = "target")
#'   ),
#'   edges = list(
#'     create_column_edge("orders", "amount", "out", "total"),
#'     create_column_edge("orders", "tax", "out", "total")
#'   )
#' )
#' lineage_diff(old, new)
lineage_diff <- function(old, new) {
  check_lineage(old)
  check_lineage(new)

  edge_cols <- c("source_table", "source_column", "target_table", "target_column")
  old_full <- lineage_edges(old)
  new_full <- lineage_edges(new)
  old_edges <- old_full[edge_cols]
  new_edges <- new_full[edge_cols]
  edge_key <- function(d) {
    paste0(d$source_table, ".", d$source_column, "->", d$target_table, ".", d$target_column)
  }

  # Edges whose endpoints match but whose definition differs
  old_keys <- edge_key(old_edges)
  new_keys <- edge_key(new_edges)
  common <- intersect(old_keys, new_keys)
  oi <- match(common, old_keys)
  ni <- match(common, new_keys)
  chg <- field_differs(old_full$transformation[oi], new_full$transformation[ni]) |
    field_differs(old_full$expression[oi], new_full$expression[ni])
  changed_edges <- data.frame(
    old_full[oi[chg], edge_cols, drop = FALSE],
    old_transformation = old_full$transformation[oi][chg],
    new_transformation = new_full$transformation[ni][chg],
    old_expression = old_full$expression[oi][chg],
    new_expression = new_full$expression[ni][chg],
    stringsAsFactors = FALSE
  )

  node_columns_df <- function(lineage) {
    rows <- lapply(lineage$nodes, function(n) {
      cols <- as.character(unlist(n$data$columns))
      data.frame(table = rep(n$id, length(cols)), column = cols, stringsAsFactors = FALSE)
    })
    if (length(rows) == 0) {
      return(data.frame(table = character(), column = character(), stringsAsFactors = FALSE))
    }
    do.call(rbind, rows)
  }
  old_cols <- node_columns_df(old)
  new_cols <- node_columns_df(new)
  col_key <- function(d) paste0(d$table, ".", d$column)

  reset <- function(d) {
    rownames(d) <- NULL
    d
  }

  added_edges <- reset(new_edges[!new_keys %in% old_keys, ])
  removed_edges <- reset(old_edges[!old_keys %in% new_keys, ])
  changed_edges <- reset(changed_edges)
  added_columns <- reset(new_cols[!col_key(new_cols) %in% col_key(old_cols), ])
  removed_columns <- reset(old_cols[!col_key(old_cols) %in% col_key(new_cols), ])

  added_edges$severity <- rep("non-breaking", nrow(added_edges))
  removed_edges$severity <-
    change_severity(old, removed_edges$target_table, removed_edges$target_column)
  changed_edges$severity <-
    change_severity(old, changed_edges$target_table, changed_edges$target_column)
  added_columns$severity <- rep("non-breaking", nrow(added_columns))
  removed_columns$severity <-
    change_severity(old, removed_columns$table, removed_columns$column)

  structure(
    list(
      added_edges = added_edges,
      removed_edges = removed_edges,
      changed_edges = changed_edges,
      added_columns = added_columns,
      removed_columns = removed_columns
    ),
    class = "dplyneage_lineage_diff"
  )
}

#' @rdname lineage_diff
#' @param diff The result of `lineage_diff()`.
#' @export
lineage_has_changes <- function(diff) {
  if (!inherits(diff, "dplyneage_lineage_diff")) {
    stop("`diff` must be the result of lineage_diff().", call. = FALSE)
  }
  sum(vapply(diff, nrow, integer(1))) > 0
}

#' NA-safe "values differ": one side NA, or both present and unequal
#' @noRd
field_differs <- function(a, b) {
  xor(is.na(a), is.na(b)) | (!is.na(a) & !is.na(b) & a != b)
}

#' One "old => new" description per changed edge: the expression rewrite
#' when it changed, else the reclassification
#' @noRd
changed_edge_desc <- function(d) {
  ifelse(
    field_differs(d$old_expression, d$new_expression),
    paste0(d$old_expression, " => ", d$new_expression),
    paste0(d$old_transformation, " => ", d$new_transformation)
  )
}

#' @noRd
breaking_flag <- function(d) {
  ifelse(d$severity == "breaking", " [breaking]", "")
}

#' @export
print.dplyneage_lineage_diff <- function(x, ...) {
  if (sum(vapply(x, nrow, integer(1))) == 0) {
    cat("No lineage changes.\n")
    return(invisible(x))
  }

  edge_lines <- function(d, sign) {
    paste0(
      "  ", sign, " ", d$source_table, ".", d$source_column,
      " -> ", d$target_table, ".", d$target_column, breaking_flag(d)
    )
  }
  col_lines <- function(d, sign) {
    paste0("  ", sign, " ", d$table, ".", d$column, breaking_flag(d))
  }

  cat("<dplyneage lineage diff>\n")
  if (nrow(x$added_edges)) {
    cat("Added edges:\n", paste(edge_lines(x$added_edges, "+"), collapse = "\n"), "\n", sep = "")
  }
  if (nrow(x$removed_edges)) {
    cat("Removed edges:\n", paste(edge_lines(x$removed_edges, "-"), collapse = "\n"), "\n", sep = "")
  }
  if (nrow(x$changed_edges)) {
    d <- x$changed_edges
    lines <- paste0(
      "  ~ ", d$source_table, ".", d$source_column,
      " -> ", d$target_table, ".", d$target_column, ": ",
      changed_edge_desc(d), breaking_flag(d)
    )
    cat("Changed edges:\n", paste(lines, collapse = "\n"), "\n", sep = "")
  }
  if (nrow(x$added_columns)) {
    cat("Added columns:\n", paste(col_lines(x$added_columns, "+"), collapse = "\n"), "\n", sep = "")
  }
  if (nrow(x$removed_columns)) {
    cat("Removed columns:\n", paste(col_lines(x$removed_columns, "-"), collapse = "\n"), "\n", sep = "")
  }
  invisible(x)
}
