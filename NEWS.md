# dplyneage (development version)

* New `lineage_mermaid()` exports lineage as a Mermaid flowchart — paste
  it into a ` ```mermaid ` fence and it renders natively on GitHub, in
  Quarto, and in most documentation tools, with no htmlwidget involved.
  Tables draw as colored subgraphs, non-identity edges carry their
  expression, and indirect edges draw dashed.

* New `include_indirect` argument for `extract_lineage()`: columns used in
  `filter()`/`WHERE`, join conditions, `group_by()`, and
  `arrange()`/`ORDER BY` — which shape the result without appearing in
  it — draw as dashed edges to each output column, classified by use
  (`"filter"`, `"join"`, `"group_by"`, `"sort"`). Impact analysis via
  `lineage_upstream()`/`lineage_downstream()` then sees them too: dropping
  a column used only in a `filter()` still breaks the pipeline. Both
  engines support it, and multi-model pipelines stitch indirect edges
  across layers.

* `extract_lineage()` now stitches multi-model pipelines: pass a named
  list of lazy tables or SQL strings (one element per model) and any
  source table matching another element's name links to that model's
  node, so a bronze/silver/gold flow renders as one multi-hop DAG.
  Intermediate models draw as orange transform nodes, terminal models as
  green targets, and `metadata$models` records each model's SQL and
  engine.

* Diagrams are laid out by a height-aware layered algorithm: each
  pipeline hop advances one column, nodes stack with spacing that
  accounts for their column count (tall tables no longer overlap), and
  layers are vertically centered.

* The ducklake vignette now ends with the stitched whole-lake diagram and
  a transitive `lineage_upstream()` impact query.

* `extract_lineage()` results are now classed `dplyneage_lineage` with a
  compact print method summarising engine, tables, output columns, and
  edge count.

* New `lineage_edges()` and `lineage_tables()` flatten a lineage object
  into plain data frames — one classified row per column edge, one row per
  table.

* Lineage edges are now classified as `identity`, `aggregation`, or
  `transformation` (mirroring OpenLineage's transformation types) in both
  engines. Diagrams label non-identity edges with the column's defining
  expression and animate aggregations automatically; `lineage_json()` and
  `lineage_graphml()` carry the classification and expression on each
  edge.

* New `lineage_diff()` compares two extractions and reports added/removed
  edges and columns — extract lineage on two branches and fail CI when
  column provenance changed.

* New `lineage_upstream()` and `lineage_downstream()` answer impact
  questions ("what feeds this column?" / "what does this column feed?")
  by transitive traversal, without exporting to igraph first.

* reticulate has moved from Imports to Suggests: dbplyr pipelines are
  analyzed entirely in R, so Python tooling is now only installed by users
  who analyze raw SQL. `extract_lineage()` and `has_sqlglot()` explain the
  requirement when reticulate is missing.

* Schema-qualified tables keep their qualifier: `stg.orders` and
  `raw.orders` are now distinct nodes in both engines instead of merging
  into one `orders` node, `extract_lineage()`'s `schema` argument accepts
  qualified names (`list("stg.orders" = ...)`), and automatic schema
  harvesting looks qualified tables up correctly.

* `extract_lineage()` no longer lets a real table named `output` collide
  with the synthetic output node, and sources whose table cannot be
  determined (`NA` or empty names) now connect to the `unknown` node
  instead of producing dangling edges.

* The sqlglot engine now records each output column's actual defining
  expression (previously it recorded the column name), matching the R
  engine.

* `metadata$table_count` is now `metadata$node_count`, since it counts all
  diagram nodes including the output node.

* The static SVG fallback in `lineage_flow()` escapes table labels before
  inserting them into HTML.

* `lineage_flow()` now routes each target column's edges through its own
  vertical lane instead of bending every edge at the same midpoint, so
  parallel edges no longer draw on top of each other. Edges fanning into
  the same target column still merge into one lane on purpose. Lanes are
  fractions of the source-to-target span, so they hold up when nodes are
  dragged.

* New vignette `vignette("ducklake-lineage")` shows dplyneage working with
  [ducklake](https://github.com/tgerke/ducklake-r): lineage for lake
  pipelines, per-layer diagrams, and time-travel queries (#1).

* New `lineage_json()` and `lineage_graphml()` export `extract_lineage()`
  results (or hand-built node/edge lists) to interchange formats: a clean
  JSON schema for scripting, CI diffs, and data catalogs, and column-level
  GraphML that loads directly into igraph, Gephi, or yEd for impact
  analysis.

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
