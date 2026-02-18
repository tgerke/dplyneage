# Example: Automatic Column Lineage from dplyr/dbplyr Pipelines
#
# This example demonstrates using sqlglot to automatically extract
# column lineage from dplyr/dbplyr queries

library(dplyneage)
library(dplyr)
library(dbplyr)
library(duckdb)

# First, install Python dependencies (only needed once)
# install_sqlglot()

# Check if sqlglot is available
if (!has_sqlglot()) {
  message("Installing sqlglot Python package...")
  install_sqlglot()
  stop("Please restart R and re-run this example after installation completes.")
}

# ============================================================================
# Example 1: Simple SELECT with transformations
# ============================================================================

con <- dbConnect(duckdb::duckdb(), ":memory:")

# Create sample data
customers <- tibble(
  customer_id = 1:5,
  first_name = c("Alice", "Bob", "Charlie", "Diana", "Eve"),
  last_name = c("Smith", "Jones", "Brown", "Davis", "Wilson"),
  email = paste0(tolower(first_name), "@example.com"),
  signup_date = as.Date("2024-01-01") + 0:4
)

orders <- tibble(
  order_id = 1:10,
  customer_id = rep(1:5, each = 2),
  order_date = as.Date("2024-01-01") + 0:9,
  amount = c(100, 150, 200, 75, 300, 125, 180, 90, 250, 160)
)

# Copy to database
copy_to(con, customers, "customers", temporary = FALSE, overwrite = TRUE)
copy_to(con, orders, "orders", temporary = FALSE, overwrite = TRUE)

# Build a dplyr pipeline
customer_summary <- tbl(con, "customers") |>
  select(customer_id, first_name, last_name, email) |>
  left_join(tbl(con, "orders"), by = "customer_id") |>
  group_by(customer_id, first_name, last_name, email) |>
  summarise(
    total_orders = n(),
    total_spent = sum(amount, na.rm = TRUE),
    avg_order = mean(amount, na.rm = TRUE),
    .groups = "drop"
  )

# View the generated SQL
show_query(customer_summary)

# Extract lineage automatically
lineage <- extract_lineage(customer_summary)

# Visualize the lineage
lineage_flow(lineage$nodes, lineage$edges, height = "600px")

# Print metadata
print(lineage$metadata)

# ============================================================================
# Example 2: Complex query with multiple operations
# ============================================================================

complex_query <- tbl(con, "customers") |>
  filter(signup_date >= as.Date("2024-01-02")) |>
  mutate(full_name = paste(first_name, last_name)) |>
  select(customer_id, full_name, email) |>
  inner_join(
    tbl(con, "orders") |>
      filter(amount > 100) |>
      select(customer_id, order_id, amount, order_date),
    by = "customer_id"
  ) |>
  arrange(desc(amount))

# Show the SQL
show_query(complex_query)

# Extract and visualize lineage
lineage2 <- extract_lineage(complex_query)
lineage_flow(lineage2$nodes, lineage2$edges, height = "700px")

# ============================================================================
# Example 3: Using raw SQL directly
# ============================================================================

raw_sql <- "
SELECT 
  c.customer_id,
  c.first_name || ' ' || c.last_name as customer_name,
  c.email,
  COUNT(o.order_id) as order_count,
  SUM(o.amount) as total_revenue,
  MAX(o.order_date) as last_order_date
FROM customers c
LEFT JOIN orders o ON c.customer_id = o.customer_id
WHERE c.signup_date >= '2024-01-01'
GROUP BY c.customer_id, c.first_name, c.last_name, c.email
HAVING SUM(o.amount) > 200
ORDER BY total_revenue DESC
"

# Extract lineage from raw SQL
lineage3 <- extract_lineage(raw_sql, dialect = "duckdb")
lineage_flow(lineage3$nodes, lineage3$edges, height = "650px")

# ============================================================================
# Example 4: Pipeline-style lineage creation
# ============================================================================

# You can also use the pipe-friendly workflow
tbl(con, "customers") |>
  select(customer_id, email, signup_date) |>
  left_join(
    tbl(con, "orders") |>
      group_by(customer_id) |>
      summarise(total = sum(amount)),
    by = "customer_id"
  ) |>
  extract_lineage() |>
  (\(x) lineage_flow(x$nodes, x$edges))()

# Clean up
dbDisconnect(con)

# ============================================================================
# Notes on SQL Dialects
# ============================================================================

# The extract_lineage function supports multiple SQL dialects:
# - "duckdb" (default)
# - "postgres"
# - "mysql"
# - "snowflake"
# - "bigquery"
# - "redshift"
# - "sqlite"
# - and many more supported by sqlglot
#
# Specify the dialect to match your database:
# extract_lineage(query, dialect = "postgres")
