# Multi-model pipelines: extract_lineage() on a named list analyzes each
# element separately, then stitches the results into one multi-hop graph.
# A source table whose name matches another element's name links to that
# model's node, so a bronze -> silver -> gold flow renders as one DAG.

#' Extract and stitch lineage for a named list of models
#' @noRd
extract_lineage_pipeline <- function(models, dialect, schema, show_sql, engine) {
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
    extract_lineage_data(model, dialect, schema, show_sql, engine)
  })

  convert_pipeline_to_graph(model_data, dialect)
}

#' Stitch per-model lineage_data into one multi-hop graph
#' @noRd
convert_pipeline_to_graph <- function(model_data, dialect) {
  model_names <- names(model_data)

  model_outputs <- lapply(model_data, function(d) {
    unique(vapply(d$columns, function(col) col$output_name, character(1)))
  })

  base_cols <- list() # base table -> referenced columns
  model_extra <- list() # model -> columns read downstream but not in outputs
  referenced <- character() # models some other model reads from
  deps <- list() # model -> upstream node ids, for layering
  edges <- list()

  for (m in model_names) {
    for (col in model_data[[m]]$columns) {
      for (source in col$sources) {
        st <- source_table_name(source)
        if (st == m) {
          stop(
            "Model '", m, "' reads from a table with the same name; ",
            "models and their source tables need distinct names.",
            call. = FALSE
          )
        }
        if (st %in% model_names) {
          referenced <- union(referenced, st)
          if (!source$column_name %in% model_outputs[[st]]) {
            model_extra[[st]] <- union(model_extra[[st]], source$column_name)
          }
        } else {
          base_cols[[st]] <- union(base_cols[[st]], source$column_name)
        }
        deps[[m]] <- union(deps[[m]], st)
        edges[[length(edges) + 1]] <- lineage_edge_for(col, source, m)
      }
    }
  }

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

  structure(
    list(
      nodes = nodes,
      edges = edges,
      metadata = list(
        dialect = dialect,
        engine = if (length(unique(engines)) == 1) unique(engines) else "mixed",
        models = lapply(model_data, function(d) {
          list(sql = d$sql, engine = d$engine %||% "sqlglot")
        }),
        node_count = length(nodes),
        edge_count = length(edges)
      )
    ),
    class = "dplyneage_lineage"
  )
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
