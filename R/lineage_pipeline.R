# Multi-model pipelines: extract_lineage() on a named list analyzes each
# element separately, then stitches the results into one multi-hop graph.
# A source table whose name matches another element's name links to that
# model's node, so a bronze -> silver -> gold flow renders as one DAG.

#' Extract and stitch lineage for a named list of models
#' @noRd
extract_lineage_pipeline <- function(models, dialect, schema, labels, show_sql,
                                     engine, include_indirect = FALSE) {
  nms <- names(models)
  if (
    length(models) == 0 || is.null(nms) || any(!nzchar(nms)) ||
      anyDuplicated(nms) > 0
  ) {
    stop(
      "A pipeline must be a named list with a unique, non-empty name per ",
      "model, e.g. list(silver = ..., gold = ...). Names become the model ",
      "nodes that stitch the graph together.",
      call. = FALSE
    )
  }

  model_data <- lapply(models, function(model) {
    extract_lineage_data(
      model, dialect, schema, labels, show_sql, engine, include_indirect
    )
  })

  convert_pipeline_to_graph(model_data)
}

#' Stitch per-model lineage_data into one multi-hop graph
#' @noRd
convert_pipeline_to_graph <- function(model_data) {
  model_names <- names(model_data)

  model_outputs <- lapply(model_data, function(d) {
    unique(vapply(d$columns, function(col) col$output_name, character(1)))
  })

  base_cols <- list() # base table -> referenced columns
  model_extra <- list() # model -> columns read downstream but not in outputs
  referenced <- character() # models some other model reads from
  deps <- list() # model -> upstream node ids, for layering
  edges <- list()

  # Classify one source table for model m (base table vs upstream model)
  # and record the node column and layering dependency it implies
  register_source <- function(m, source) {
    st <- source_table_name(source)
    if (st == m) {
      stop(
        "Model '", m, "' reads from a table with the same name; ",
        "models and their source tables need distinct names.",
        call. = FALSE
      )
    }
    if (st %in% model_names) {
      referenced <<- union(referenced, st)
      if (!source$column_name %in% model_outputs[[st]]) {
        model_extra[[st]] <<- union(model_extra[[st]], source$column_name)
      }
    } else {
      base_cols[[st]] <<- union(base_cols[[st]], source$column_name)
    }
    deps[[m]] <<- union(deps[[m]], st)
    st
  }

  for (m in model_names) {
    edge_keys <- character()
    for (col in model_data[[m]]$columns) {
      for (source in col$sources) {
        st <- register_source(m, source)
        edges[[length(edges) + 1]] <- lineage_edge_for(col, source, m)
        edge_keys <- c(
          edge_keys,
          paste0(st, ".", source$column_name, "->", col$output_name)
        )
      }
    }
    # Indirect columns (filter/join/group/sort) connect to every output
    # column of this model, dashed, skipping pairs a direct edge covers.
    # A pair reached through several kinds keeps one edge recording all
    # of them
    indirect_at <- integer()
    for (source in model_data[[m]]$indirect %||% list()) {
      st <- register_source(m, source)
      for (output_column in model_outputs[[m]]) {
        key <- paste0(st, ".", source$column_name, "->", output_column)
        if (key %in% edge_keys) next
        at <- indirect_at[key]
        if (!is.na(at)) {
          edges[[at]] <- add_indirect_kind(edges[[at]], source$kind)
          next
        }
        edges[[length(edges) + 1]] <- indirect_edge_for(source, m, output_column)
        indirect_at[[key]] <- length(edges)
      }
    }
  }

  warn_unstitched_models(base_cols, model_names, model_outputs, model_extra)

  # Longest-path layering: base tables sit in layer 0, every model at
  # least one layer right of everything it reads from
  base_names <- names(base_cols)
  ids <- c(base_names, model_names)
  layers <- stats::setNames(
    c(rep(0L, length(base_names)), rep(1L, length(model_names))),
    ids
  )
  iterations <- 0L
  repeat {
    changed <- FALSE
    for (m in model_names) {
      for (up in deps[[m]]) {
        if (layers[[m]] < layers[[up]] + 1L) {
          layers[[m]] <- layers[[up]] + 1L
          changed <- TRUE
        }
      }
    }
    if (!changed) break
    iterations <- iterations + 1L
    if (iterations > length(ids)) {
      stop("The pipeline's models reference each other in a cycle.", call. = FALSE)
    }
  }

  # Column types for base tables, merged across models: the first model
  # whose harvested or supplied schema typed a table wins. Labels merge
  # the same way, and apply to model nodes too — a labels= entry keyed
  # by a model name documents columns that model computes
  base_types <- list()
  all_labels <- list()
  for (d in model_data) {
    for (tbl in names(d$column_types %||% list())) {
      if (is.null(base_types[[tbl]])) {
        base_types[[tbl]] <- d$column_types[[tbl]]
      }
    }
    all_labels <- merge_label_maps(all_labels, d$column_labels %||% list())
  }

  specs <- c(
    lapply(base_names, function(nm) {
      list(
        id = nm,
        columns = base_cols[[nm]],
        type = "source",
        layer = layers[[nm]],
        types = spec_types(base_types, nm, base_cols[[nm]]),
        labels = spec_types(all_labels, nm, base_cols[[nm]])
      )
    }),
    lapply(model_names, function(nm) {
      columns <- c(model_outputs[[nm]], model_extra[[nm]])
      list(
        id = nm,
        columns = columns,
        type = if (nm %in% referenced) "transform" else "target",
        layer = layers[[nm]],
        labels = spec_types(all_labels, nm, columns)
      )
    })
  )
  nodes <- build_layout_nodes(specs)

  engines <- vapply(
    model_data,
    function(d) d$engine %||% "sqlglot",
    character(1)
  )
  dialects <- vapply(
    model_data,
    function(d) d$dialect %||% "duckdb",
    character(1)
  )

  nodes <- propagate_column_metadata(nodes, edges)
  edges <- dedupe_edge_labels(edges)

  structure(
    list(
      nodes = nodes,
      edges = edges,
      metadata = list(
        dialect = if (length(unique(dialects)) == 1) unique(dialects) else "mixed",
        engine = if (length(unique(engines)) == 1) unique(engines) else "mixed",
        models = lapply(model_data, function(d) {
          # Only when captured: a NULL entry would serialize to JSON as
          # {}. sql can be NULL for engines with no query text (arrow)
          m <- list()
          if (!is.null(d$sql)) {
            m$sql <- d$sql
          }
          m$engine <- d$engine %||% "sqlglot"
          m$dialect <- d$dialect %||% "duckdb"
          if (!is.null(d$namespace)) {
            m$namespace <- d$namespace
          }
          m
        }),
        node_count = length(nodes),
        edge_count = length(edges)
      )
    ),
    class = "dplyneage_lineage"
  )
}

#' Warn when a base table resembles a model it did not stitch to
#'
#' Stitching matches the engine's source-table name to model names by
#' exact string, so `main.silver` or `SILVER` never links to a model
#' named `silver` — the graph silently renders disconnected. When an
#' unstitched base table shares a model's final name component
#' (case-insensitively) and reads only columns that model carries, it is
#' probably that model's materialization, so say so.
#' @noRd
warn_unstitched_models <- function(base_cols, model_names, model_outputs,
                                   model_extra) {
  last_component <- function(x) {
    parts <- strsplit(x, ".", fixed = TRUE)[[1]]
    parts[[length(parts)]]
  }
  pairs <- character()
  for (bt in names(base_cols)) {
    for (m in model_names) {
      if (tolower(last_component(bt)) != tolower(last_component(m))) next
      if (!all(base_cols[[bt]] %in% c(model_outputs[[m]], model_extra[[m]]))) next
      pairs <- c(pairs, paste0("'", bt, "' (model '", m, "')"))
    }
  }
  if (length(pairs) == 0) {
    return(invisible(NULL))
  }
  warning(
    "Some source tables were not stitched to similarly named models: ",
    paste(pairs, collapse = ", "),
    ". Stitching matches names exactly. If a table is a model's ",
    "materialization, give the model the table's full name, e.g. ",
    "extract_lineage(list(\"main.silver\" = ...)), or reference the ",
    "table by the model's exact name.",
    call. = FALSE
  )
  invisible(NULL)
}

#' Build one lineage edge from a column's source, carrying classification
#'
#' Non-identity edges are labeled with the column's defining expression;
#' aggregations are animated.
#' @noRd
lineage_edge_for <- function(col, source, target_table) {
  type <- col$type
  labeled <- !is.null(type) && type != "identity" && !is.null(col$expression)
  edge <- create_column_edge(
    from_table = source_table_name(source),
    from_column = source$column_name,
    to_table = target_table,
    to_column = col$output_name,
    label = if (labeled) truncate_label(col$expression) else NULL,
    animated = identical(type, "aggregation")
  )
  if (!is.null(type)) {
    edge$data <- list(expression = col$expression, transformation = type)
  }
  edge
}

#' Record an additional indirect classification on an existing edge
#'
#' A source column can shape the same output through several indirect
#' kinds (filtered on and sorted on, say). The diagram keeps one dashed
#' edge; `data$transformation` stays the first kind and the full set
#' accumulates in `data$transformations`, which the JSON and OpenLineage
#' exports read.
#' @noRd
add_indirect_kind <- function(edge, kind) {
  edge$data$transformations <- union(
    edge$data$transformations %||% edge$data$transformation,
    kind
  )
  edge
}

#' Build one dashed indirect-lineage edge
#'
#' Indirect sources are the filter/join/group/sort columns collected under
#' `include_indirect = TRUE`: `list(table, column_name, kind)`. They carry
#' their kind as the edge classification and no defining expression.
#' @noRd
indirect_edge_for <- function(source, target_table, target_column) {
  edge <- create_column_edge(
    from_table = source_table_name(source),
    from_column = source$column_name,
    to_table = target_table,
    to_column = target_column
  )
  edge$style$stroke <- "#94a3b8"
  edge$style$strokeDasharray <- "6 4"
  edge$data <- list(transformation = source$kind)
  edge
}

#' Create positioned table nodes from specs (id, columns, type, layer)
#'
#' Layered layout: x advances one column per layer; within a layer nodes
#' stack with spacing that accounts for their column count, and shorter
#' layers are centered against the tallest one.
#' @noRd
build_layout_nodes <- function(specs) {
  if (length(specs) == 0) {
    return(list())
  }
  layers <- vapply(specs, function(s) s$layer, integer(1))
  n_columns <- vapply(specs, function(s) length(s$columns), integer(1))
  pos <- layout_positions(layers, n_columns)
  lapply(seq_along(specs), function(i) {
    node <- create_table_node(
      table_name = specs[[i]]$id,
      columns = specs[[i]]$columns,
      x = pos$x[[i]],
      y = pos$y[[i]],
      table_type = specs[[i]]$type
    )
    if (length(specs[[i]]$types) > 0) {
      node$data$columnTypes <- as.list(specs[[i]]$types)
    }
    if (length(specs[[i]]$labels) > 0) {
      node$data$columnLabels <- as.list(specs[[i]]$labels)
    }
    node
  })
}

#' Propagate column types and labels along identity edges
#'
#' dbt-Catalog-style passthrough: a column with no type or label of its
#' own inherits its source column's through any chain of identity edges.
#' Aggregations, transformations, and indirect edges propagate nothing,
#' and a column fed conflicting values by several identity edges stays
#' bare — missing beats wrong. Candidate sets flow to a fixpoint before
#' anything commits, so the outcome doesn't depend on edge order and
#' ambiguity carries through multi-hop chains.
#' @noRd
propagate_column_metadata <- function(nodes, edges) {
  node_ids <- vapply(nodes, function(n) n$id, character(1))
  id_edges <- Filter(function(e) {
    identical(e$data$transformation, "identity") &&
      isTRUE(e$source %in% node_ids) && isTRUE(e$target %in% node_ids)
  }, edges)
  if (length(id_edges) == 0) {
    return(nodes)
  }

  for (field in c("columnTypes", "columnLabels")) {
    # A column's own value is a barrier: never overwritten, and passed
    # on in place of anything accumulated behind it
    own <- list()
    for (n in nodes) {
      for (col in names(n$data[[field]])) {
        own[[paste0(n$id, "\r", col)]] <- n$data[[field]][[col]]
      }
    }
    acc <- list()
    outset <- function(key) {
      if (!is.null(own[[key]])) own[[key]] else acc[[key]] %||% character(0)
    }
    # Sets only grow, so this reaches a fixpoint; the cap is insurance
    # the layered DAG (cycles are rejected upstream) never needs
    for (pass in seq_len(length(nodes) + length(id_edges))) {
      changed <- FALSE
      for (e in id_edges) {
        tkey <- paste0(e$target, "\r", e$targetHandle)
        if (!is.null(own[[tkey]])) next
        add <- setdiff(
          outset(paste0(e$source, "\r", e$sourceHandle)),
          acc[[tkey]]
        )
        if (length(add) > 0) {
          acc[[tkey]] <- c(acc[[tkey]], add)
          changed <- TRUE
        }
      }
      if (!changed) break
    }
    # Commit only unambiguous values, and only into missing slots
    for (i in seq_along(nodes)) {
      for (col in as.character(unlist(nodes[[i]]$data$columns))) {
        key <- paste0(node_ids[[i]], "\r", col)
        vals <- unique(acc[[key]])
        if (is.null(own[[key]]) && length(vals) == 1) {
          nodes[[i]]$data[[field]][[col]] <- vals
        }
      }
    }
  }
  nodes
}

#' Keep one expression label per output column
#'
#' A computed column with several sources emits one edge per source, each
#' carrying the same defining expression, so the diagram drew the label
#' once per edge. The expression describes the output column, not the
#' individual edge, so it belongs on the group once. The renderer anchors
#' labels to the target row, meaning every edge in a group would draw in
#' the same spot; the first labeled edge keeps it for determinism.
#'
#' Sibling edges that somehow carry different expressions join with " | "
#' rather than losing one. `data$expression` stays on every edge, so the
#' hover card, `lineage_edges()`, and the exports are untouched.
#' @noRd
dedupe_edge_labels <- function(edges) {
  if (length(edges) == 0) {
    return(edges)
  }
  keys <- vapply(
    edges,
    function(e) paste0(e$target, "\r", e$targetHandle),
    character(1)
  )
  labeled <- vapply(edges, function(e) !is.null(e$label), logical(1))

  for (key in unique(keys[labeled])) {
    idx <- which(keys == key & labeled)
    # Hand-built edges can carry a label with no expression behind it
    exprs <- unique(unlist(lapply(
      edges[idx],
      function(e) e$data$expression %||% e$label
    )))
    # Narrower than truncate_label()'s default: these render right-aligned
    # into the corridor between nodes, and lineage_mermaid() keeps 40
    edges[[idx[[1]]]]$label <- truncate_label(
      paste(exprs, collapse = " | "),
      max = 34
    )
    for (i in idx[-1]) {
      edges[[i]]$label <- NULL
      edges[[i]]$labelStyle <- NULL
      edges[[i]]$labelBgStyle <- NULL
    }
  }
  edges
}

#' @noRd
layout_positions <- function(layers, n_columns, x_spacing = 400, y_gap = 60) {
  # Approximate rendered node height: header plus one row per column
  heights <- 44 + 33 * n_columns
  # Widening x_spacing to give right-aligned edge labels more corridor
  # backfires: fitView scales the graph to its frame, so a wider layout
  # renders every node smaller. A bigger screenshot doesn't recover it
  # either, since the graph's own width sets the scale. Labels are
  # capped instead, in dedupe_edge_labels().
  x <- (layers - min(layers)) * x_spacing
  y <- numeric(length(layers))

  unique_layers <- unique(layers)
  totals <- vapply(unique_layers, function(l) {
    idx <- layers == l
    sum(heights[idx]) + y_gap * (sum(idx) - 1)
  }, numeric(1))
  tallest <- max(totals)

  for (i in seq_along(unique_layers)) {
    idx <- which(layers == unique_layers[[i]])
    stacked <- cumsum(c(0, (heights[idx] + y_gap)[-length(idx)]))
    y[idx] <- stacked + (tallest - totals[[i]]) / 2
  }

  list(x = x, y = y)
}
