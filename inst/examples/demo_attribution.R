library(dplyneage)
library(dplyr)
library(duckdb)

# Ensure latest code is loaded
devtools::load_all()

cat("=================================================================\n")
cat("  Testing Improved Column Attribution Heuristics\n")
cat("=================================================================\n\n")

con <- dbConnect(duckdb())

# Create test data (matching structure that triggers customers.* pattern)
customers <- tibble::tibble(
  id = 1:5,
  name = paste("Customer", 1:5)
)

orders <- tibble::tibble(
  order_id = 1:10,  # Include order_id to trigger customers.* pattern
  customer_id = rep(1:5, each = 2),
  amount = seq(100, 1000, by = 100)
)

dbWriteTable(con, "customers", customers, overwrite = TRUE)
dbWriteTable(con, "orders", orders, overwrite = TRUE)

cat("Test scenario: customers LEFT JOIN orders\n")
cat("  - customers.* selected (id, name, city)\n")
cat("  - orders.amount selected (standalone column)\n\n")

# Build query using typical dplyr pattern
query <- tbl(con, "customers") |>
  left_join(tbl(con, "orders"), by = c("id" = "customer_id")) |>
  select(id, name, amount) |>
  group_by(id, name) |>
  summarize(total = sum(amount, na.rm = TRUE))

cat("Generated SQL:\n")
cat(paste(strwrap(as.character(dbplyr::sql_render(query)), width = 70), 
    collapse = "\n"), "\n\n")

cat("Extracting lineage...\n")
lineage <- query |> extract_lineage()

cat("\nColumn Attribution Results:\n")
cat(rep("-", 65), "\n", sep = "")
cat(sprintf("%-20s | %-40s\n", "Table", "Columns"))
cat(rep("-", 65), "\n", sep = "")

for (node in lineage$nodes) {
  if (node$data$tableType != "target") {
    cols <- paste(node$data$columns, collapse = ", ")
    cat(sprintf("%-20s | %-40s\n", node$data$label, cols))
  }
}

cat(rep("-", 65), "\n\n", sep = "")

cat("Lineage Edges (Column Flow):\n")
cat(rep("-", 65), "\n", sep = "")
for (edge in lineage$edges) {
  from <- paste(edge$source, edge$sourceHandle, sep = ".")
  to <- paste(edge$target, edge$targetHandle, sep = ".")
  cat(sprintf("  %s  →  %s\n", from, to))
}
cat(rep("-", 65), "\n\n", sep = "")

cat("✅ Expected behavior:\n")
cat("  ✓ 'id' and 'name' attributed to 'customers' (from SELECT customers.*)\n")
cat("  ✓ 'amount' attributed to 'orders' (standalone column from JOIN)\n")
cat("  ✓ 'total' in output derived from orders.amount\n\n")

cat("Creating visualization...\n\n")

# Cleanup database connection first
dbDisconnect(con)

# Create and display widget
# For source(), use html_print to force viewer display
viz <- lineage |> lineage_flow(height = "600px")
htmltools::html_print(viz)
