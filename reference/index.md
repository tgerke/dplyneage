# Package index

## Main Functions

Core functions for extracting and visualizing lineage

- [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  : Extract column lineage from a dplyr pipeline or SQL query
- [`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md)
  : Render an interactive column lineage diagram
- [`lineage_example()`](https://tgerke.github.io/dplyneage/reference/lineage_example.md)
  : A built-in example lineage diagram
- [`lineage_flowOutput()`](https://tgerke.github.io/dplyneage/reference/lineage_flow-shiny.md)
  [`renderLineageFlow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow-shiny.md)
  : Shiny bindings for lineage_flow

## Manual Lineage Creation

Functions for manually creating lineage visualizations

- [`create_table_node()`](https://tgerke.github.io/dplyneage/reference/create_table_node.md)
  : Create a table node for a lineage diagram
- [`create_column_edge()`](https://tgerke.github.io/dplyneage/reference/create_column_edge.md)
  : Connect two columns in a lineage diagram

## Export

Serialize lineage to interchange formats for graph tools, CI, and data
catalogs

- [`lineage_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md)
  : Export lineage as JSON
- [`lineage_graphml()`](https://tgerke.github.io/dplyneage/reference/lineage_graphml.md)
  : Export lineage as GraphML

## Python Integration

Python (sqlglot) is only used for raw SQL input and is provisioned
automatically; this helper checks availability

- [`has_sqlglot()`](https://tgerke.github.io/dplyneage/reference/has_sqlglot.md)
  : Is the Python sqlglot dependency available?

## Bundle Management

The React Flow bundle ships pre-built; this helper checks it exists

- [`has_bundle()`](https://tgerke.github.io/dplyneage/reference/has_bundle.md)
  : Is the React Flow bundle available?
