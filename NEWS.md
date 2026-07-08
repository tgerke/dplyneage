# dplyneage (development version)

* `extract_lineage()` now analyzes dbplyr lazy tables with a pure-R engine
  that walks the pipeline's lazy query tree — no Python required. Column
  provenance is read directly from the tree, so joins (including suffix
  conflicts and coalesced full-join keys), aggregates, window expressions,
  and set operations resolve exactly.
* New `engine` argument for `extract_lineage()`: `"auto"` (the default)
  uses the R engine for lazy tables and falls back to sqlglot for SQL
  strings or constructs the R engine cannot trace, such as raw SQL injected
  with `dbplyr::sql()`; `"r"` and `"sqlglot"` force a specific engine.
  Requires dbplyr >= 2.5.0 for the R engine.
* `extract_lineage()` results now record which engine ran in
  `metadata$engine`.

# dplyneage 0.1.0

First public release.

## Features

* `extract_lineage()` extracts column-level lineage from dplyr/dbplyr
  pipelines or raw SQL strings, powered by sqlglot's lineage engine.
  Aliases, CTEs, subqueries, set operations (UNION), and multi-source
  computed columns (e.g. `COALESCE(a.x, b.x)`) all resolve to their true
  source columns.
* Schema-aware column attribution: when given a dbplyr lazy table,
  `extract_lineage()` automatically reads each referenced table's columns
  from the database connection so unqualified columns are attributed to the
  correct table and `SELECT *` expands. For raw SQL, pass the new `schema`
  argument.
* `lineage_flow()` renders interactive React Flow diagrams with
  column-level edges, draggable table nodes, hover highlighting, and
  zoom/pan controls. Accepts `extract_lineage()` output directly in a pipe.
* `create_table_node()` and `create_column_edge()` for building lineage
  diagrams manually, plus `lineage_example()` as a built-in demo.
* Shiny bindings via `lineage_flowOutput()` and `renderLineageFlow()`.
* Multiple SQL dialects supported via sqlglot (DuckDB default; PostgreSQL,
  MySQL, Snowflake, BigQuery, and more).
* Python dependencies are provisioned automatically through
  `reticulate::py_require()` — no manual setup step. `install_sqlglot()` is
  deprecated and does nothing.

## Notes

* Works out of the box with any package that produces dbplyr lazy tables,
  including [ducklake](https://github.com/tgerke/ducklake-r).
* The React Flow JavaScript bundle ships pre-built with the package.
