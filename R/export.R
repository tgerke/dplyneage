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
#' @return A JSON string. With `metadata` (present on [extract_lineage()]
#'   results), `nodes` (objects with `id`, `type`, and `columns`), and
#'   `edges` (objects with `source`, `source_column`, `target`, and
#'   `target_column`).
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
#' @examplesIf dplyneage::has_sqlglot()
#' extract_lineage("SELECT customer_id, SUM(amount) AS total
#'                  FROM orders GROUP BY customer_id") |>
#'   lineage_json()
lineage_json <- function(lineage, path = NULL, pretty = TRUE) {
  out <- jsonlite::toJSON(
    lineage_semantics(lineage),
    auto_unbox = TRUE,
    pretty = pretty
  )
  write_export(out, path)
}

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
    list(
      id = n$id,
      type = n$data$tableType,
      # I() keeps a single column serializing as a JSON array, not a scalar
      columns = I(as.character(unlist(n$data$columns)))
    )
  })

  edges <- lapply(lineage$edges, function(e) {
    list(
      source = e$source,
      source_column = e$sourceHandle,
      target = e$target,
      target_column = e$targetHandle
    )
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
    paste0(
      '    <edge source="', xml_escape(paste0(e$source, ".", e$source_column)),
      '" target="', xml_escape(paste0(e$target, ".", e$target_column)), '"/>'
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
