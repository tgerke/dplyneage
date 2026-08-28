#' Export lineage as JSON
#'
#' Serializes a lineage object to a small, stable JSON document: node ids
#' with their columns and table type, plus one record per column-level
#' edge. React Flow presentation details (positions, colors) are
#' deliberately dropped, so the output is suitable for scripting with jq,
#' committing to version control (a CI diff catches accidental provenance
#' changes when a pipeline is edited), or feeding to a data catalog.
#'
#' @param lineage The result of [extract_lineage()], or any list with
#'   `nodes` and `edges` built with [create_table_node()] and
#'   [create_column_edge()].
#' @param path Optional file to write the JSON to. When supplied, the
#'   string is returned invisibly.
#' @param pretty If `TRUE` (the default), indent the output for
#'   readability. Use `FALSE` for a single-line document.
#' @return A JSON string; see the Document shape section.
#' @section Document shape:
#' The top-level keys, in order:
#'
#' * `format_version`: integer version of this document shape, currently
#'   1. It bumps only when a change would break an existing consumer;
#'   added fields do not bump it.
#' * `metadata`: present on [extract_lineage()] results. Carries
#'   `dialect`, `engine`, `models`, `node_count`, and `edge_count`.
#'   `models` maps each model name to its `sql`, `engine`, and
#'   `dialect`; a single-query extraction is a one-model map keyed by
#'   the output table's name, so consumers read per-model SQL the same
#'   way for both shapes. A model extracted from a table on a live
#'   database connection also carries `namespace`, the OpenLineage
#'   namespace URI inferred from that connection. The top-level
#'   `dialect` and `engine` collapse across models, to `"mixed"` when
#'   models disagree.
#' * `nodes`: objects with `id`, `type` (`"source"`, `"transform"`, or
#'   `"target"`), and `columns`. A source node whose column types were
#'   captured (from a live connection's schema, or a typed `schema`
#'   argument) also carries `types`, a column-to-type map covering the
#'   typed subset of its columns.
#' * `edges`: objects with `source`, `source_column`, `target`, and
#'   `target_column`. Edges from [extract_lineage()] also carry
#'   `transformation` and, on direct edges, `expression`. An indirect
#'   edge whose column shapes the result in several ways (filtered and
#'   sorted on, say) adds `transformations`, the full set of kinds with
#'   the first one leading.
#' @family lineage exporters
#' @seealso [extract_lineage()] to compute lineage automatically
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
#' lineage_json(lineage)
#'
#' # Write to a file instead
#' path <- tempfile(fileext = ".json")
#' lineage_json(lineage, path = path)
#' @examplesIf identical(Sys.getenv("NOT_CRAN"), "true") && dplyneage::has_sqlglot()
#' extract_lineage("SELECT customer_id, SUM(amount) AS total
#'                  FROM orders GROUP BY customer_id") |>
#'   lineage_json()
lineage_json <- function(lineage, path = NULL, pretty = TRUE) {
  out <- jsonlite::toJSON(
    c(list(format_version = lineage_json_version), lineage_semantics(lineage)),
    auto_unbox = TRUE,
    pretty = pretty
  )
  write_export(out, path)
}

# Version of the lineage_json() document shape. Bump only when a change
# would break an existing consumer; added fields do not bump it.
lineage_json_version <- 1L

#' Export lineage as GraphML
#'
#' Serializes a lineage object to [GraphML](http://graphml.graphdrawing.org/),
#' the XML graph format read by igraph, Gephi, yEd, and most other graph
#' tools. Each table column becomes a node (id `"table.column"`, duplicated
#' in a `name` attribute so igraph picks it up as the vertex name) with
#' `table`, `column`, and `node_type` attributes; each column-level edge
#' becomes a directed edge. That granularity is what makes the export
#' useful downstream: `igraph::subcomponent(g, "output.total", mode = "in")`
#' lists every source column feeding an output, and Gephi can color the
#' graph by `table`.
#'
#' @inheritParams lineage_json
#' @param path Optional file to write the GraphML to. When supplied, the
#'   string is returned invisibly.
#' @return A string containing the GraphML document.
#' @family lineage exporters
#' @seealso [extract_lineage()] to compute lineage automatically
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
#' cat(lineage_graphml(lineage))
#'
#' # Round-trip through igraph for ancestry queries
#' @examplesIf requireNamespace("igraph", quietly = TRUE)
#' path <- tempfile(fileext = ".graphml")
#' lineage_graphml(lineage, path = path)
#' g <- igraph::read_graph(path, format = "graphml")
#' igraph::subcomponent(g, "daily_totals.total", mode = "in")
lineage_graphml <- function(lineage, path = NULL) {
  out <- build_graphml(lineage_semantics(lineage))
  write_export(out, path)
}

#' Export lineage as a Mermaid flowchart
#'
#' Serializes a lineage object to [Mermaid](https://mermaid.js.org/)
#' flowchart text. Mermaid renders natively in GitHub markdown, Quarto,
#' and most documentation tools, so this is the exporter to reach for when
#' lineage should live *in the docs*: paste the output into a
#' ` ```mermaid ` code fence and the diagram renders with no R, no
#' htmlwidget, and no JavaScript bundle.
#'
#' Each table becomes a subgraph containing its columns, colored by table
#' type with the same palette as [lineage_flow()]. Non-identity edges are
#' labeled with the column's defining expression, and indirect edges
#' (from `extract_lineage(include_indirect = TRUE)`) draw dashed.
#'
#' @inheritParams lineage_json
#' @param path Optional file to write the Mermaid text to. When supplied,
#'   the string is returned invisibly.
#' @return A string containing the Mermaid flowchart definition.
#' @family lineage exporters
#' @seealso [extract_lineage()] to compute lineage automatically
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
#' cat(lineage_mermaid(lineage))
#'
#' # Ready to paste into a GitHub README or Quarto document:
#' cat("```mermaid\n", lineage_mermaid(lineage), "```\n", sep = "")
lineage_mermaid <- function(lineage, path = NULL) {
  out <- build_mermaid(lineage_semantics(lineage))
  write_export(out, path)
}

#' @noRd
build_mermaid <- function(semantics) {
  tables <- vapply(semantics$nodes, function(n) n$id, character(1))
  keys <- c(
    paste0("t\r", tables),
    unlist(lapply(semantics$nodes, function(n) paste0("c\r", n$id, ".", n$columns)))
  )
  ids <- mermaid_id_map(keys)
  table_id <- function(table) ids[[paste0("t\r", table)]]
  column_id <- function(table, col) ids[[paste0("c\r", table, ".", col)]]

  lines <- "flowchart LR"
  for (n in semantics$nodes) {
    lines <- c(lines, paste0(
      "  subgraph ", table_id(n$id), "[", mermaid_label(n$id), "]"
    ))
    for (col in n$columns) {
      lines <- c(lines, paste0(
        "    ", column_id(n$id, col), "[", mermaid_label(col), "]"
      ))
    }
    lines <- c(lines, "  end")
  }

  indirect_kinds <- c("filter", "join", "group_by", "sort")
  for (e in semantics$edges) {
    from <- column_id(e$source, e$source_column)
    to <- column_id(e$target, e$target_column)
    arrow <- if (isTRUE(e$transformation %in% indirect_kinds)) {
      " -.-> "
    } else if (!is.null(e$expression) &&
      !identical(e$transformation, "identity")) {
      paste0(" -->|", mermaid_label(truncate_label(e$expression)), "| ")
    } else {
      " --> "
    }
    lines <- c(lines, paste0("  ", from, arrow, to))
  }

  # Same palette as create_table_node(); classes color the subgraph frames
  lines <- c(
    lines,
    "  classDef source fill:#f0f7ff,stroke:#3b82f6,color:#1d4ed8",
    "  classDef transform fill:#fef3f2,stroke:#f59e0b,color:#d97706",
    "  classDef target fill:#f0fdf4,stroke:#10b981,color:#059669"
  )
  for (n in semantics$nodes) {
    if (isTRUE(n$type %in% c("source", "transform", "target"))) {
      lines <- c(lines, paste0("  class ", table_id(n$id), " ", n$type))
    }
  }

  paste0(paste(lines, collapse = "\n"), "\n")
}

# Mermaid node ids share one namespace (subgraphs included), must avoid
# reserved words like "end", and only safely allow [A-Za-z0-9_]
#' @noRd
mermaid_id_map <- function(keys) {
  ids <- sub("^[tc]\r", "", keys)
  ids <- gsub("[^A-Za-z0-9_]", "_", ids)
  digits <- grepl("^[0-9]", ids)
  ids[digits] <- paste0("n", ids[digits])
  reserved <- c(
    "end", "subgraph", "graph", "flowchart", "class", "classDef",
    "style", "linkStyle", "click", "direction"
  )
  ids[ids %in% reserved] <- paste0(ids[ids %in% reserved], "_")
  while (anyDuplicated(ids) > 0) {
    dup <- duplicated(ids)
    ids[dup] <- paste0(ids[dup], "_")
  }
  stats::setNames(as.list(ids), keys)
}

# Quoted Mermaid labels tolerate most characters; double quotes become
# the #quot; entity
#' @noRd
mermaid_label <- function(x) {
  paste0('"', gsub('"', "#quot;", x, fixed = TRUE), '"')
}

# Duck-type the extract_lineage() contract, same as lineage_flow()
#' @noRd
check_lineage <- function(lineage) {
  if (!is.list(lineage) || is.null(lineage$nodes) || is.null(lineage$edges)) {
    stop(
      "`lineage` must be the result of extract_lineage(), or a list with ",
      "`nodes` and `edges` built with create_table_node() and ",
      "create_column_edge()",
      call. = FALSE
    )
  }
}

# Reduce the graph object to the format-independent structure both
# exporters serialize: metadata (when present), nodes, edges — with the
# React Flow presentation fields stripped
#' @noRd
lineage_semantics <- function(lineage) {
  check_lineage(lineage)

  nodes <- lapply(lineage$nodes, function(n) {
    node <- list(
      id = n$id,
      type = n$data$tableType,
      # I() keeps a single column serializing as a JSON array, not a scalar
      columns = I(as.character(unlist(n$data$columns)))
    )
    if (!is.null(n$data$columnTypes)) {
      node$types <- n$data$columnTypes
    }
    node
  })

  edges <- lapply(lineage$edges, function(e) {
    edge <- list(
      source = e$source,
      source_column = e$sourceHandle,
      target = e$target,
      target_column = e$targetHandle
    )
    # extract_lineage() edges carry a classification, and direct ones the
    # defining expression; hand-built edges carry neither, and indirect
    # (filter/join/group/sort) edges have no expression
    if (!is.null(e$data$transformation)) {
      edge$transformation <- e$data$transformation
      # An indirect edge reached through several kinds carries them all,
      # first kind leading
      if (length(e$data$transformations) > 1) {
        edge$transformations <- I(as.character(e$data$transformations))
      }
      if (!is.null(e$data$expression)) {
        edge$expression <- e$data$expression
      }
    }
    edge
  })

  semantics <- list(nodes = nodes, edges = edges)
  if (!is.null(lineage$metadata)) {
    semantics <- c(list(metadata = lineage$metadata), semantics)
  }
  semantics
}

#' @noRd
xml_escape <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x <- gsub("\"", "&quot;", x, fixed = TRUE)
  gsub("'", "&apos;", x, fixed = TRUE)
}

#' @noRd
build_graphml <- function(semantics) {
  node_xml <- unlist(lapply(semantics$nodes, function(n) {
    vapply(n$columns, function(col) {
      id <- xml_escape(paste0(n$id, ".", col))
      paste0(
        '    <node id="', id, '">\n',
        '      <data key="name">', id, "</data>\n",
        '      <data key="table">', xml_escape(n$id), "</data>\n",
        '      <data key="column">', xml_escape(col), "</data>\n",
        '      <data key="node_type">', xml_escape(n$type), "</data>\n",
        "    </node>"
      )
    }, character(1))
  }))

  edge_xml <- vapply(semantics$edges, function(e) {
    open <- paste0(
      '    <edge source="', xml_escape(paste0(e$source, ".", e$source_column)),
      '" target="', xml_escape(paste0(e$target, ".", e$target_column)), '"'
    )
    if (is.null(e$transformation)) {
      return(paste0(open, "/>"))
    }
    expression_xml <- if (is.null(e$expression)) {
      ""
    } else {
      paste0(
        '      <data key="expression">', xml_escape(e$expression), "</data>\n"
      )
    }
    paste0(
      open, ">\n",
      '      <data key="transformation">', xml_escape(e$transformation),
      "</data>\n",
      expression_xml,
      "    </edge>"
    )
  }, character(1))

  paste0(
    '<?xml version="1.0" encoding="UTF-8"?>\n',
    '<graphml xmlns="http://graphml.graphdrawing.org/xmlns"\n',
    '         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"\n',
    '         xsi:schemaLocation="http://graphml.graphdrawing.org/xmlns',
    ' http://graphml.graphdrawing.org/xmlns/1.0/graphml.xsd">\n',
    '  <key id="name" for="node" attr.name="name" attr.type="string"/>\n',
    '  <key id="table" for="node" attr.name="table" attr.type="string"/>\n',
    '  <key id="column" for="node" attr.name="column" attr.type="string"/>\n',
    '  <key id="node_type" for="node" attr.name="node_type" attr.type="string"/>\n',
    '  <key id="transformation" for="edge" attr.name="transformation" attr.type="string"/>\n',
    '  <key id="expression" for="edge" attr.name="expression" attr.type="string"/>\n',
    '  <graph id="lineage" edgedefault="directed">\n',
    paste0(c(node_xml, edge_xml, "  </graph>"), collapse = "\n"), "\n",
    "</graphml>\n"
  )
}

#' @noRd
write_export <- function(out, path) {
  if (is.null(path)) {
    return(out)
  }
  writeLines(enc2utf8(out), path, useBytes = TRUE)
  invisible(out)
}
