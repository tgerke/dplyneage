# arrow lineage engine: walks arrow_dplyr_query objects — the lazy
# structure arrow's dplyr verbs build over Tables, RecordBatches, and
# Datasets — and emits the same lineage_data shape as the other native
# walkers. There is no SQL anywhere: the query compiles to an Acero
# plan, so `sql` stays NULL and `dialect` is the "arrow" sentinel.
#
# The query internals are not exported arrow API; everything handled
# here was verified against arrow 25.0.1 (and matches the 17.0.0
# sources): selected_columns holds one Expression per visible column
# with renames recorded by name; expressions are inlined eagerly, so
# Expression$field_names_in_expression() always yields names of the
# node's .data columns; summarise/join/union_all collapse into a nested
# query carrying group_by_vars + aggregations, $join, or $union_all;
# distinct() is a zero-aggregation group_by; .keep_all rides on the
# "one" aggregate; grouped mutate compiles to a self-join against an
# aggregation node, which the join handling covers with no special
# case. Join outputs come from left_output/right_output with dplyr's
# suffixes applied to conflicts, so a full join's key coalesce
# (coalesce(id.x, id.y)) resolves in the outer projection on its own.
#
# rlang is guaranteed here for obj_address(): the walker only runs when
# arrow is installed, and arrow imports rlang.

#' Is the arrow lineage engine usable?
#'
#' The floor matches the oldest sources the walker's structures were
#' checked against; see the file header.
#' @noRd
arrow_engine_available <- function() {
  requireNamespace("arrow", quietly = TRUE) &&
    utils::packageVersion("arrow") >= "17.0.0"
}

#' Extract lineage from an arrow query (or bare Table/Dataset)
#'
#' Returns lineage_data with `engine = "arrow"`, `dialect = "arrow"`,
#' and `sql = NULL` — there is no query text to record. `schema` is
#' part of the uniform engine interface but unused: types come from the
#' arrow schema itself.
#' @noRd
extract_lineage_from_arrow <- function(x, include_indirect = FALSE,
                                       schema = NULL) {
  collector <- new.env(parent = emptyenv())
  collector$labels <- list()
  collector$types <- list()
  collector$base_names <- new.env(parent = emptyenv())
  collector$file_based <- FALSE
  if (include_indirect) {
    collector$sources <- list()
  }
  cols <- arrow_walk(x, collector)
  out <- assemble_lineage_data(
    cols, collector, include_indirect,
    sql = NULL,
    dialect = "arrow",
    engine = "arrow"
  )
  if (length(collector$types) > 0) {
    out$column_types <- collector$types
  }
  if (collector$file_based) {
    out$namespace <- "file"
  }
  out
}

#' Walk one arrow node (query or base data) into a column map
#' @noRd
arrow_walk <- function(x, collector) {
  if (inherits(x, "arrow_dplyr_query")) {
    return(arrow_walk_query(x, collector))
  }
  arrow_walk_base(x, collector)
}

#' @noRd
arrow_walk_query <- function(q, collector) {
  inner <- arrow_walk(q$.data, collector)

  # The visible projection. Expressions are inlined down to .data's
  # column names, so everything resolves against `inner`
  map <- list()
  for (nm in names(q$selected_columns)) {
    map[[nm]] <- arrow_col_entry(q$selected_columns[[nm]], inner)
  }

  if (!isTRUE(q$filtered_rows) && !is.null(q$filtered_rows)) {
    note_indirect(
      collector, "filter",
      q$filtered_rows$field_names_in_expression(), inner
    )
  }
  for (arr in q$arrange_vars %||% list()) {
    note_indirect(collector, "sort", arr$field_names_in_expression(), inner)
  }

  aggs <- q$aggregations
  if (!is.null(aggs)) {
    # An aggregation node's outputs are its group keys then its
    # aggregates; other selected columns only feed the aggregates.
    # distinct() arrives as zero aggregations over group keys, which
    # stays indirect-silent like SELECT DISTINCT elsewhere
    out <- list()
    for (g in q$group_by_vars) {
      entry <- map[[g]]
      if (is.null(entry)) {
        arrow_bookkeeping_stop("group keys")
      }
      out[[g]] <- entry
    }
    if (length(aggs) > 0) {
      note_indirect(collector, "group_by", q$group_by_vars, map)
    }
    for (nm in names(aggs)) {
      out[[nm]] <- arrow_agg_entry(aggs[[nm]], inner)
    }
    map <- out
  }

  join <- q$join
  if (!is.null(join)) {
    map <- arrow_walk_join(join, map, collector)
  }

  if (!is.null(q$union_all)) {
    map <- merge_column_maps(
      map,
      arrow_walk(q$union_all$right_data, collector)
    )
  }

  map
}

#' One column entry from a selected_columns Expression
#' @noRd
arrow_col_entry <- function(expr, inner) {
  fields <- expr$field_names_in_expression()
  if (expr$is_field_ref()) {
    entry <- inner[[fields[[1]]]]
    if (is.null(entry)) {
      arrow_bookkeeping_stop("column references")
    }
    return(entry)
  }
  vars <- intersect(fields, names(inner))
  list(
    expression = expr$ToString(),
    type = "transformation",
    sources = combine_sources(lapply(vars, function(v) inner[[v]]$sources))
  )
}

#' One column entry from an aggregation spec (fun, data, options)
#'
#' `"one"` backs distinct(.keep_all = TRUE): it picks a row's value, so
#' the underlying column passes through unchanged and identity chains
#' keep propagating. `"count_all"` is n(): no sources at all.
#' @noRd
arrow_agg_entry <- function(agg, inner) {
  fields <- unique(unlist(lapply(
    agg$data,
    function(d) d$field_names_in_expression()
  )))
  if (identical(agg$fun, "one") && length(fields) == 1 &&
        !is.null(inner[[fields[[1]]]])) {
    return(inner[[fields[[1]]]])
  }
  vars <- intersect(fields, names(inner))
  args <- vapply(agg$data, function(d) d$ToString(), character(1))
  list(
    expression = paste0(agg$fun, "(", paste(args, collapse = ", "), ")"),
    type = "aggregation",
    sources = combine_sources(lapply(vars, function(v) inner[[v]]$sources))
  )
}

# arrow's Acero join types, from arrow:::JoinType (stable since 6.0)
arrow_join_semi_anti <- c(0L, 1L, 2L, 3L)
arrow_right_outer <- 6L

#' Resolve a $join field against the node's own (left) column map
#'
#' left_output/right_output name the surviving columns per side;
#' conflicts get dplyr's suffixes, which is exactly how the outer
#' projection references them (a full join's key arrives there as
#' coalesce(id.x, id.y) and picks up both sides on its own).
#' @noRd
arrow_walk_join <- function(join, left_map, collector) {
  type <- as.integer(join$type)
  by <- join$by
  left_keys <- names(by) %||% unname(by)
  right_keys <- unname(by)

  if (type %in% arrow_join_semi_anti) {
    # The right side only filters rows; walk it just for indirect keys
    if (collecting(collector)) {
      note_indirect(collector, "join", left_keys, left_map)
      note_indirect(
        collector, "join", right_keys,
        arrow_walk(join$right_data, collector)
      )
    }
    return(left_map)
  }

  right_map <- arrow_walk(join$right_data, collector)
  note_indirect(collector, "join", left_keys, left_map)
  note_indirect(collector, "join", right_keys, right_map)

  out <- list()
  for (nm in join$left_output) {
    entry <- left_map[[nm]]
    if (is.null(entry)) {
      arrow_bookkeeping_stop("join outputs")
    }
    out_name <- if (nm %in% join$right_output) {
      paste0(nm, join$suffix[[1]])
    } else {
      nm
    }
    out[[out_name]] <- entry
  }
  for (nm in join$right_output) {
    entry <- right_map[[nm]]
    if (is.null(entry)) {
      arrow_bookkeeping_stop("join outputs")
    }
    out_name <- if (nm %in% join$left_output) {
      paste0(nm, join$suffix[[2]])
    } else {
      nm
    }
    out[[out_name]] <- entry
  }
  out
}

#' Identity map for a base Table/RecordBatch/Dataset/reader
#' @noRd
arrow_walk_base <- function(x, collector) {
  if (
    !inherits(
      x,
      c("Table", "RecordBatch", "Dataset", "RecordBatchReader")
    )
  ) {
    unsupported_lineage(
      paste0("arrow inputs of class <", class(x)[[1]], ">")
    )
  }
  table <- arrow_base_name(x, collector)
  schema <- x$schema
  cols <- lapply(names(schema), function(v) {
    list(
      expression = v,
      type = "identity",
      sources = list(list(table = table, column_name = v))
    )
  })
  names(cols) <- names(schema)

  if (is.null(collector$types[[table]])) {
    collector$types[[table]] <- stats::setNames(
      vapply(schema$fields, function(f) f$type$ToString(), character(1)),
      names(schema)
    )
  }
  labs <- arrow_metadata_labels(x)
  if (length(labs) > 0 && is.null(collector$labels[[table]])) {
    collector$labels[[table]] <- labs
  }
  cols
}

#' Name a base object, stably per object within one walk
#'
#' File-backed datasets are named by their file (or the files' common
#' directory); in-memory data gets arrow_table, arrow_table_2, ...,
#' keyed by object identity so the same Table joined with itself stays
#' one node.
#' @noRd
arrow_base_name <- function(x, collector) {
  address <- rlang::obj_address(x)
  known <- collector$base_names[[address]]
  if (!is.null(known)) {
    return(known)
  }
  name <- if (inherits(x, "FileSystemDataset")) {
    collector$file_based <- TRUE
    files <- x$files
    if (length(files) == 1) files else dirname(files[[1]])
  } else {
    taken <- as.character(mget(
      ls(collector$base_names),
      envir = collector$base_names
    ))
    candidate <- "arrow_table"
    k <- 1L
    while (candidate %in% taken) {
      k <- k + 1L
      candidate <- paste0("arrow_table_", k)
    }
    candidate
  }
  collector$base_names[[address]] <- name
  name
}

#' haven/labelled label attributes preserved in the arrow metadata
#' @noRd
arrow_metadata_labels <- function(x) {
  meta <- tryCatch(x$metadata$r$columns, error = function(e) NULL)
  if (is.null(meta)) {
    return(NULL)
  }
  labs <- lapply(meta, function(col) col$attributes$label)
  keep <- vapply(
    labs,
    function(l) is.character(l) && length(l) == 1 && !is.na(l) && nzchar(l),
    logical(1)
  )
  if (!any(keep)) {
    return(NULL)
  }
  vapply(labs[keep], identity, character(1))
}

#' @noRd
arrow_bookkeeping_stop <- function(what) {
  unsupported_lineage(
    paste0(
      "this arrow query's ", what,
      " (an arrow internals change?)"
    )
  )
}
