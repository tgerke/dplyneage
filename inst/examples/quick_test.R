# Minimal working example to verify lineage extraction and visualization
library(dplyneage)
library(dplyr)
library(duckdb)

# Create connection
con <- dbConnect(duckdb(), ":memory:")

copy_to(con,
  tibble(id = 1:5, name = c("Alice", "Bob", "Charlie", "Diana", "Eve")),
  "customers", overwrite = TRUE)

copy_to(con,
  tibble(order_id = 1:10, customer_id = rep(1:5, each = 2),
         amount = c(100, 150, 200, 75, 300, 125, 180, 90, 250, 160)),
  "orders", overwrite = TRUE)

tbl(con, "customers") |>
  select(id, name) |>
  left_join(tbl(con, "orders"), by = c("id" = "customer_id")) |>
  group_by(id, name) |>
  summarise(total = sum(amount, na.rm = TRUE), .groups = "drop") |>
  extract_lineage(show_sql = TRUE) |>
  lineage_flow(height = "600px")

dbDisconnect(con)
