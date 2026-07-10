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
#' edges.
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

  seen <- character()
  frontier <- column
  while (length(frontier) > 0) {
    frontier <- setdiff(unique(step_to[step_from %in% frontier]), seen)
    seen <- c(seen, frontier)
  }
  sort(seen)
}

#' Compare two lineage extractions
#'
#' Reports the column-level edges and table columns that were added or
#' removed between two lineage objects — typically the same pipeline
#' before and after an edit. This makes the CI story concrete: extract
#' lineage on both branches and fail (or comment) when provenance changed.
#'
#' @param old,new Lineage objects from [extract_lineage()] (or lists with
#'   `nodes` and `edges`), in before/after order.
#' @return A `dplyneage_lineage_diff` list with data frame elements
#'   `added_edges`, `removed_edges`, `added_columns`, and
#'   `removed_columns`. Its print method summarises the changes;
#'   zero-row elements mean no change.
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
  old_edges <- lineage_edges(old)[edge_cols]
  new_edges <- lineage_edges(new)[edge_cols]
  edge_key <- function(d) {
    paste0(d$source_table, ".", d$source_column, "->", d$target_table, ".", d$target_column)
  }

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

  structure(
    list(
      added_edges = reset(new_edges[!edge_key(new_edges) %in% edge_key(old_edges), ]),
      removed_edges = reset(old_edges[!edge_key(old_edges) %in% edge_key(new_edges), ]),
      added_columns = reset(new_cols[!col_key(new_cols) %in% col_key(old_cols), ]),
      removed_columns = reset(old_cols[!col_key(old_cols) %in% col_key(new_cols), ])
    ),
    class = "dplyneage_lineage_diff"
  )
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
      " -> ", d$target_table, ".", d$target_column
    )
  }
  col_lines <- function(d, sign) paste0("  ", sign, " ", d$table, ".", d$column)

  cat("<dplyneage lineage diff>\n")
  if (nrow(x$added_edges)) {
    cat("Added edges:\n", paste(edge_lines(x$added_edges, "+"), collapse = "\n"), "\n", sep = "")
  }
  if (nrow(x$removed_edges)) {
    cat("Removed edges:\n", paste(edge_lines(x$removed_edges, "-"), collapse = "\n"), "\n", sep = "")
  }
  if (nrow(x$added_columns)) {
    cat("Added columns:\n", paste(col_lines(x$added_columns, "+"), collapse = "\n"), "\n", sep = "")
  }
  if (nrow(x$removed_columns)) {
    cat("Removed columns:\n", paste(col_lines(x$removed_columns, "-"), collapse = "\n"), "\n", sep = "")
  }
  invisible(x)
}
