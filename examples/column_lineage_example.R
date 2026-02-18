# Column Lineage Example
# This script demonstrates how to create professional column-level lineage diagrams
# inspired by dbt, SQLMesh, OpenMetadata, and OpenLineage

# Load the package
devtools::load_all()

# Method 1: Use the built-in example
# This is the quickest way to see column-level lineage in action
lineage_example()

# Method 2: Create a custom column lineage diagram
# This example shows customer data flowing through transformations

# Define source tables
customers_table <- create_table_node(
  table_name = "customers",
  columns = c("customer_id", "name", "email", "signup_date"),
  x = 0,
  y = 50,
  table_type = "source"  # Blue color scheme
)

orders_table <- create_table_node(
  table_name = "orders",
  columns = c("order_id", "customer_id", "order_date", "total_amount"),
  x = 0,
  y = 300,
  table_type = "source"  # Blue color scheme
)

# Define target/output table
customer_summary_table <- create_table_node(
  table_name = "customer_summary",
  columns = c("customer_id", "customer_name", "email", "first_order", "total_spent"),
  x = 500,
  y = 150,
  table_type = "target"  # Green color scheme
)

# Create column-to-column edges showing data flow and transformations
edges <- list(
  # Direct column mappings (no transformation)
  create_column_edge(
    "customers", "customer_id", 
    "customer_summary", "customer_id"
  ),
  
  # Column rename
  create_column_edge(
    "customers", "name", 
    "customer_summary", "customer_name"
  ),
  
  # Direct pass-through
  create_column_edge(
    "customers", "email", 
    "customer_summary", "email"
  ),
  
  # Aggregation (MIN) with animation
  create_column_edge(
    "orders", "order_date", 
    "customer_summary", "first_order",
    label = "MIN()",
    animated = TRUE
  ),
  
  # Aggregation (SUM) with animation
  create_column_edge(
    "orders", "total_amount", 
    "customer_summary", "total_spent",
    label = "SUM()",
    animated = TRUE
  )
)

# Render the lineage diagram
lineage_flow(
  nodes = list(customers_table, orders_table, customer_summary_table),
  edges = edges,
  height = "600px"
)

# Method 3: More complex example with intermediate transformations
# This shows a data pipeline with a transform step

products <- create_table_node(
  table_name = "products",
  columns = c("product_id", "name", "category", "price"),
  x = 0,
  y = 0,
  table_type = "source"
)

order_items <- create_table_node(
  table_name = "order_items", 
  columns = c("order_id", "product_id", "quantity", "unit_price"),
  x = 0,
  y = 200,
  table_type = "source"
)

# Intermediate transformation
enriched_orders <- create_table_node(
  table_name = "enriched_orders",
  columns = c("order_id", "product_name", "category", "quantity", "line_total"),
  x = 300,
  y = 100,
  table_type = "transform"  # Orange color scheme
)

# Final output
sales_by_category <- create_table_node(
  table_name = "sales_by_category",
  columns = c("category", "total_quantity", "total_revenue"),
  x = 600,
  y = 100,
  table_type = "target"
)

pipeline_edges <- list(
  # products -> enriched_orders
  create_column_edge("products", "name", "enriched_orders", "product_name"),
  create_column_edge("products", "category", "enriched_orders", "category"),
  
  # order_items -> enriched_orders
  create_column_edge("order_items", "order_id", "enriched_orders", "order_id"),
  create_column_edge("order_items", "quantity", "enriched_orders", "quantity"),
  create_column_edge("order_items", "unit_price", "enriched_orders", "line_total", 
                    label = "qty * price", animated = TRUE),
  
  # enriched_orders -> sales_by_category
  create_column_edge("enriched_orders", "category", "sales_by_category", "category"),
  create_column_edge("enriched_orders", "quantity", "sales_by_category", "total_quantity",
                    label = "SUM()", animated = TRUE),
  create_column_edge("enriched_orders", "line_total", "sales_by_category", "total_revenue",
                    label = "SUM()", animated = TRUE)
)

lineage_flow(
  nodes = list(products, order_items, enriched_orders, sales_by_category),
  edges = pipeline_edges,
  height = "600px"
)
