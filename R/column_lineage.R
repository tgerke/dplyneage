#' Create a table node for a lineage diagram
#'
#' Builds one table, with its columns, for lineage diagrams rendered by
#' [lineage_flow()]. Use this together with [create_column_edge()] when you
#' want full control over the diagram instead of extracting lineage
#' automatically.
#'
#' @param table_name Name shown in the node header. Also used as the node
#'   id, so it must be unique within a diagram.
#' @param columns Character vector of column names listed in the node. Each
#'   column gets connection handles that edges can attach to.
#' @param x,y Position of the node on the canvas, in pixels. Nodes remain
#'   draggable, so these only set the starting layout.
#' @param table_type One of `"source"` (blue), `"transform"` (orange), or
#'   `"target"` (green). The colors follow the conventions used by tools
#'   like dbt and SQLMesh.
#' @return A node list ready to pass to [lineage_flow()]
#' @family manual lineage builders
#' @seealso [extract_lineage()] to build nodes and edges automatically
#' @export
#' @examples
#' create_table_node(
#'   table_name = "customers",
#'   columns = c("id", "name", "email"),
#'   table_type = "source"
#' )
create_table_node <- function(table_name, columns, x = 0, y = 0, table_type = "source") {
  # Color scheme based on industry standards (dbt, SQLMesh, OpenMetadata)
  colors <- list(
    source = list(bg = "#f0f7ff", border = "#3b82f6", header = "#1d4ed8"),
    transform = list(bg = "#fef3f2", border = "#f59e0b", header = "#d97706"),
    target = list(bg = "#f0fdf4", border = "#10b981", header = "#059669")
  )
  
  type_colors <- if (!is.null(colors[[table_type]])) colors[[table_type]] else colors$source
  
  list(
    id = table_name,
    type = "tableNode",
    data = list(
      label = table_name,
      columns = columns,
      tableType = table_type,
      colors = type_colors
    ),
    position = list(x = x, y = y),
    draggable = TRUE,
    sourcePosition = "right",
    targetPosition = "left"
  )
}

#' Connect two columns in a lineage diagram
#'
#' Creates an edge from one table's column to another's, for diagrams built
#' with [create_table_node()] and rendered by [lineage_flow()]. Table and
#' column names must match the `table_name` and `columns` used when
#' creating the nodes.
#'
#' @param from_table,from_column Table and column the data comes from.
#' @param to_table,to_column Table and column the data flows into.
#' @param label Optional label drawn on the edge, typically the
#'   transformation applied (e.g. `"SUM()"`).
#' @param animated If `TRUE`, the edge is drawn with a moving dash pattern.
#'   Useful for drawing attention to aggregations.
#' @return An edge list ready to pass to [lineage_flow()]
#' @family manual lineage builders
#' @export
#' @examples
#' # A direct column mapping
#' create_column_edge("customers", "id", "customer_summary", "customer_id")
#'
#' # An aggregation, labeled and animated
#' create_column_edge("orders", "amount", "customer_summary", "total_spent",
#'   label = "SUM()", animated = TRUE
#' )
create_column_edge <- function(from_table, from_column, to_table, to_column, 
                               label = NULL, animated = FALSE) {
  edge <- list(
    id = paste0("e_", from_table, ".", from_column, "_to_", to_table, ".", to_column),
    source = from_table,
    target = to_table,
    sourceHandle = from_column,
    targetHandle = to_column,
    animated = animated,
    style = list(
      stroke = "#64748b",
      strokeWidth = 2
    )
  )
  
  if (!is.null(label)) {
    edge$label <- label
    edge$labelStyle <- list(
      fill = "#64748b",
      fontWeight = 500,
      fontSize = 11
    )
    edge$labelBgStyle <- list(
      fill = "#ffffff",
      fillOpacity = 0.9
    )
  }
  
  edge
}

#' A built-in example lineage diagram
#'
#' Renders a small customers/orders lineage diagram built with the manual
#' helpers. Handy for checking that the visualization works in your
#' environment, and as a template for building diagrams by hand.
#'
#' @return A [lineage_flow()] htmlwidget
#' @family manual lineage builders
#' @export
#' @examples
#' lineage_example()
lineage_example <- function() {
  # Create three tables with columns
  customers_table <- create_table_node(
    table_name = "customers",
    columns = c("customer_id", "name", "email", "signup_date"),
    x = 0,
    y = 50,
    table_type = "source"
  )
  
  orders_table <- create_table_node(
    table_name = "orders",
    columns = c("order_id", "customer_id", "order_date", "total_amount"),
    x = 0,
    y = 300,
    table_type = "source"
  )
  
  customer_summary_table <- create_table_node(
    table_name = "customer_summary",
    columns = c("customer_id", "customer_name", "email", "first_order", "total_spent"),
    x = 500,
    y = 150,
    table_type = "target"
  )
  
  nodes <- list(customers_table, orders_table, customer_summary_table)
  
  # Create column-level edges showing data flow
  edges <- list(
    # customer_id flows from customers to customer_summary
    create_column_edge("customers", "customer_id", "customer_summary", "customer_id"),
    
    # name becomes customer_name
    create_column_edge("customers", "name", "customer_summary", "customer_name"),
    
    # email flows through
    create_column_edge("customers", "email", "customer_summary", "email"),
    
    # order_date becomes first_order (with transformation)
    create_column_edge("orders", "order_date", "customer_summary", "first_order", 
                      label = "MIN()", animated = TRUE),
    
    # total_amount becomes total_spent (with aggregation)
    create_column_edge("orders", "total_amount", "customer_summary", "total_spent", 
                      label = "SUM()", animated = TRUE)
  )
  
  lineage_flow(nodes, edges, height = "600px")
}
