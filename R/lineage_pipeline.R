# Multi-model pipelines: extract_lineage() on a named list analyzes each
# element separately, then stitches the results into one multi-hop graph.
# A source table whose name matches another element's name links to that
# model's node, so a bronze -> silver -> gold flow renders as one DAG.

#' Extract and stitch lineage for a named list of models
#' @noRd
extract_lineage_pipeline <- function(models, dialect, schema, show_sql, engine,
                                     include_indirect = FALSE) {
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
    extract_lineage_data(model, dialect, schema, show_sql, engine, include_indirect)
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
    # column of this model, dashed, skipping pairs a direct edge covers
    for (source in model_data[[m]]$indirect %||% list()) {
      st <- register_source(m, source)
      for (output_column in model_outputs[[m]]) {
        key <- paste0(st, ".", source$column_name, "->", output_column)
        if (key %in% edge_keys) next
        edge_keys <- c(edge_keys, key)
        edges[[length(edges) + 1]] <- indirect_edge_for(source, m, output_column)
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

  specs <- c(
    lapply(base_names, function(nm) {
      list(id = nm, columns = base_cols[[nm]], type = "source", layer = layers[[nm]])
    }),
    lapply(model_names, function(nm) {
      list(
        id = nm,
        columns = c(model_outputs[[nm]], model_extra[[nm]]),
        type = if (nm %in% referenced) "transform" else "target",
        layer = layers[[nm]]
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

  structure(
    list(
      nodes = nodes,
      edges = edges,
      metadata = list(
        dialect = if (length(unique(dialects)) == 1) unique(dialects) else "mixed",
        engine = if (length(unique(engines)) == 1) unique(engines) else "mixed",
        models = lapply(model_data, function(d) {
          m <- list(
            sql = d$sql,
            engine = d$engine %||% "sqlglot",
            dialect = d$dialect %||% "duckdb"
          )
          # Only when captured: a NULL entry would serialize to JSON as {}
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
    create_table_node(
      table_name = specs[[i]]$id,
      columns = specs[[i]]$columns,
      x = pos$x[[i]],
      y = pos$y[[i]],
      table_type = specs[[i]]$type
    )
  })
}

#' @noRd
layout_positions <- function(layers, n_columns, x_spacing = 400, y_gap = 60) {
  # Approximate rendered node height: header plus one row per column
  heights <- 44 + 33 * n_columns
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
