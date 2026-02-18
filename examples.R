# Example: Simple Column Lineage Flow
# 
# This example demonstrates a basic lineage flow visualization

library(dplyneage)

# Simple example: data pipeline with 3 steps
lineage_flow(
  nodes = list(
    list(id = "1", position = list(x = 50, y = 50), data = list(label = "Source Table")),
    list(id = "2", position = list(x = 300, y = 100), data = list(label = "Transform")),
    list(id = "3", position = list(x = 550, y = 50), data = list(label = "Output Table"))
  ),
  edges = list(
    list(id = "e1-2", source = "1", target = "2"),
    list(id = "e2-3", source = "2", target = "3")
  )
)

# More complex example: multiple inputs
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
