# Changelog

## dplyneage (development version)

- [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  now analyzes dbplyr lazy tables with a pure-R engine that walks the
  pipeline’s lazy query tree — no Python required. Column provenance is
  read directly from the tree, so joins (including suffix conflicts and
  coalesced full-join keys), aggregates, window expressions, and set
  operations resolve exactly.
- New `engine` argument for
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md):
  `"auto"` (the default) uses the R engine for lazy tables and falls
  back to sqlglot for SQL strings or constructs the R engine cannot
  trace, such as raw SQL injected with
  [`dbplyr::sql()`](https://dbplyr.tidyverse.org/reference/sql.html);
  `"r"` and `"sqlglot"` force a specific engine. Requires dbplyr \>=
  2.5.0 for the R engine.
- [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  results now record which engine ran in `metadata$engine`.

## dplyneage 0.1.0

First public release.

### Features

- [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  extracts column-level lineage from dplyr/dbplyr pipelines or raw SQL
  strings, powered by sqlglot’s lineage engine. Aliases, CTEs,
  subqueries, set operations (UNION), and multi-source computed columns
  (e.g. `COALESCE(a.x, b.x)`) all resolve to their true source columns.
- Schema-aware column attribution: when given a dbplyr lazy table,
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  automatically reads each referenced table’s columns from the database
  connection so unqualified columns are attributed to the correct table
  and `SELECT *` expands. For raw SQL, pass the new `schema` argument.
- [`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md)
  renders interactive React Flow diagrams with column-level edges,
  draggable table nodes, hover highlighting, and zoom/pan controls.
  Accepts
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  output directly in a pipe.
- [`create_table_node()`](https://tgerke.github.io/dplyneage/reference/create_table_node.md)
  and
  [`create_column_edge()`](https://tgerke.github.io/dplyneage/reference/create_column_edge.md)
  for building lineage diagrams manually, plus
  [`lineage_example()`](https://tgerke.github.io/dplyneage/reference/lineage_example.md)
  as a built-in demo.
- Shiny bindings via
  [`lineage_flowOutput()`](https://tgerke.github.io/dplyneage/reference/lineage_flow-shiny.md)
  and
  [`renderLineageFlow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow-shiny.md).
- Multiple SQL dialects supported via sqlglot (DuckDB default;
  PostgreSQL, MySQL, Snowflake, BigQuery, and more).
- Python dependencies are provisioned automatically through
  [`reticulate::py_require()`](https://rstudio.github.io/reticulate/reference/py_require.html)
  — no manual setup step.
  [`install_sqlglot()`](https://tgerke.github.io/dplyneage/reference/install_sqlglot.md)
  is deprecated and does nothing.

### Notes

- Works out of the box with any package that produces dbplyr lazy
  tables, including [ducklake](https://github.com/tgerke/ducklake-r).
- The React Flow JavaScript bundle ships pre-built with the package.
