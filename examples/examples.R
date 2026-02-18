# =============================================================================
# dplyneage Examples
# =============================================================================
#
# This file contains examples demonstrating the features of dplyneage,
# from automatic lineage extraction to manual graph creation.

library(dplyneage)

# =============================================================================
# EXAMPLE 1: Automatic Lineage Extraction (Recommended)
# =============================================================================
# Extract column lineage automatically from dplyr/dbplyr pipelines

if (requireNamespace("dplyr", quietly = TRUE) && 
    requireNamespace("dbplyr", quietly = TRUE) && 
    requireNamespace("duckdb", quietly = TRUE)) {
  
  if (!has_sqlglot()) {
    message("Installing Python dependencies for automatic lineage extraction...")
    message("Run: install_sqlglot()")
    message("Then restart R and try again.")
  } else {
    library(dplyr)
    library(dbplyr)
    library(duckdb)
    
    # Create a DuckDB connection
    con <- dbConnect(duckdb::duckdb(), ":memory:")
    
    # Create sample data
    customers <- tibble(
      customer_id = 1:5,
      name = c("Alice", "Bob", "Charlie", "Diana", "Eve"),
      email = paste0(tolower(name), "@example.com")
    )
    
    orders <- tibble(
      order_id = 1:10,
      customer_id = rep(1:5, each = 2),
      amount = c(100, 150, 200, 75, 300, 125, 180, 90, 250, 160)
    )
    
    # Copy to database
    copy_to(con, customers, "customers", overwrite = TRUE)
    copy_to(con, orders, "orders", overwrite = TRUE)
    
    # Build a dplyr pipeline
    customer_summary <- tbl(con, "customers") |>
      select(customer_id, name, email) |>
      left_join(tbl(con, "orders"), by = "customer_id") |>
      group_by(customer_id, name, email) |>
      summarise(
        total_spent = sum(amount, na.rm = TRUE),
        .groups = "drop"
      )
    
    # Extract and visualize lineage automatically!
    lineage <- extract_lineage(customer_summary)
    print(lineage_flow(lineage$nodes, lineage$edges, height = "600px"))
    
    # Cleanup
    dbDisconnect(con)
  }
}

# =============================================================================
# EXAMPLE 2: Built-in Column Lineage Example
# =============================================================================
# Quick way to see column-level lineage in action

lineage_example()

# =============================================================================
# EXAMPLE 3: Manual Column Lineage Creation
# =============================================================================
# Build custom column-level lineage visualizations

# Define tables with columns
customers <- create_table_node(
  table_name = "customers",
  columns = c("customer_id", "name", "email", "signup_date"),
  x = 0,
  y = 50,
  table_type = "source"
)

orders <- create_table_node(
  table_name = "orders", 
  columns = c("order_id", "customer_id", "order_date", "total_amount"),
  x = 0,
  y = 300,
  table_type = "source"
)

customer_summary <- create_table_node(
  table_name = "customer_summary",
  columns = c("customer_id", "customer_name", "email", "first_order", "total_spent"),
  x = 500,
  y = 150,
  table_type = "target"
)

# Connect specific columns with transformation labels
edges <- list(
  create_column_edge("customers", "customer_id", "customer_summary", "customer_id"),
  create_column_edge("customers", "name", "customer_summary", "customer_name"),
  create_column_edge("customers", "email", "customer_summary", "email"),
  create_column_edge("orders", "order_date", "customer_summary", "first_order", 
                     label = "MIN()", animated = TRUE),
  create_column_edge("orders", "total_amount", "customer_summary", "total_spent",
                     label = "SUM()", animated = TRUE)
)

# Render the lineage
lineage_flow(
  nodes = list(customers, orders, customer_summary),
  edges = edges,
  height = "600px"
)

# =============================================================================
# EXAMPLE 4: Simple Table-Level Lineage
# =============================================================================
# Basic node-to-node lineage without column details

lineage_flow(
  nodes = list(
    list(id = "1", position = list(x = 0, y = 50), data = list(label = "Source Table")),
    list(id = "2", position = list(x = 300, y = 100), data = list(label = "Transform")),
    list(id = "3", position = list(x = 550, y = 50), data = list(label = "Output Table"))
  ),
  edges = list(
    list(id = "e1-2", source = "1", target = "2"),
    list(id = "e2-3", source = "2", target = "3")
  )
)

# =============================================================================
# EXAMPLE 5: Complex Multi-Input Lineage
# =============================================================================
# Multiple source tables flowing through transformations

lineage_flow(
  nodes = list(
    list(id = "sales", position = list(x = 0, y = 50), data = list(label = "sales")),
    list(id = "customers", position = list(x = 0, y = 150), data = list(label = "customers")),
    list(id = "products", position = list(x = 0, y = 250), data = list(label = "products")),
    list(id = "join1", position = list(x = 250, y = 100), data = list(label = "join sales+customers")),
    list(id = "join2", position = list(x = 250, y = 200), data = list(label = "join +products")),
    list(id = "filter", position = list(x = 500, y = 150), data = list(label = "filter 2024")),
    list(id = "summarize", position = list(x = 700, y = 150), data = list(label = "group & summarize"))
  ),
  edges = list(
    list(id = "e1", source = "sales", target = "join1"),
    list(id = "e2", source = "customers", target = "join1"),
    list(id = "e3", source = "join1", target = "join2"),
    list(id = "e4", source = "products", target = "join2"),
    list(id = "e5", source = "join2", target = "filter"),
    list(id = "e6", source = "filter", target = "summarize")
  )
)
