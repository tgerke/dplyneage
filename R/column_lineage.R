#' Create a Column Lineage Node
#'
#' Helper function to create a table node with columns for lineage visualization
#'
#' @param table_name Name of the table
#' @param columns Character vector of column names
#' @param x Horizontal position
#' @param y Vertical position
#' @param table_type Type of table: "source", "transform", or "target"
#' @return A list structure compatible with lineage_flow
#' @export
create_table_node <- function(table_name, columns, x = 0, y = 0, table_type = "source") {
  # Create unique IDs for each column
  column_ids <- paste0(table_name, ".", columns)
  
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

#' Create Column-Level Edge
#'
#' Create an edge connecting specific columns between tables
#'
#' @param from_table Source table name
#' @param from_column Source column name
#' @param to_table Target table name
#' @param to_column Target column name
#' @param label Optional edge label (e.g., transformation description)
#' @param animated Whether to animate the edge
#' @return A list structure compatible with lineage_flow
#' @export
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

#' Create Column Lineage Example
#'
#' Create an example column-level lineage visualization
#'
#' @return A lineage_flow widget
#' @export
#' @examples
#' \dontrun{
#' lineage_example()
#' }
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
