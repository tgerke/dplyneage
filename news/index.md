# Changelog

## dplyneage 0.2.0

- [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  now gives an actionable error when passed a plain data frame, pointing
  to the
  [`dbplyr::memdb_frame()`](https://dbplyr.tidyverse.org/reference/memdb.html)
  / [`copy_to()`](https://dplyr.tidyverse.org/reference/copy_to.html)
  workaround instead of failing later with a misleading message about
  Python or SQL strings. The workaround is also documented in the README
  and on
  [`?extract_lineage`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md).

- New
  [`lineage_openlineage()`](https://tgerke.github.io/dplyneage/reference/lineage_openlineage.md)
  exports lineage as an OpenLineage `RunEvent` with `ColumnLineage`
  facets — the interchange format Marquez, DataHub, and OpenMetadata
  ingest, so dplyneage-extracted lineage can sit alongside lineage from
  dbt, Airflow, or Spark. Edge classifications map to OpenLineage
  transformation types, including `INDIRECT` subtypes for
  `include_indirect` edges.

- New
  [`lineage_mermaid()`](https://tgerke.github.io/dplyneage/reference/lineage_mermaid.md)
  exports lineage as a Mermaid flowchart — paste it into a
  ```` ```mermaid ```` fence and it renders natively on GitHub, in
  Quarto, and in most documentation tools, with no htmlwidget involved.
  Tables draw as colored subgraphs, non-identity edges carry their
  expression, and indirect edges draw dashed.

- The getting-started vignette now covers local data frames: plain-dplyr
  pipelines have no lazy query tree to trace, and
  [`dbplyr::memdb_frame()`](https://dbplyr.tidyverse.org/reference/memdb.html)
  (or any
  [`copy_to()`](https://dplyr.tidyverse.org/reference/copy_to.html)) is
  the one-line workaround that makes the identical pipeline traceable.

- New `include_indirect` argument for
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md):
  columns used in
  [`filter()`](https://dplyr.tidyverse.org/reference/filter.html)/`WHERE`,
  join conditions,
  [`group_by()`](https://dplyr.tidyverse.org/reference/group_by.html),
  and
  [`arrange()`](https://dplyr.tidyverse.org/reference/arrange.html)/`ORDER BY`
  — which shape the result without appearing in it — draw as dashed
  edges to each output column, classified by use (`"filter"`, `"join"`,
  `"group_by"`, `"sort"`). Impact analysis via
  [`lineage_upstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)/[`lineage_downstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)
  then sees them too: dropping a column used only in a
  [`filter()`](https://dplyr.tidyverse.org/reference/filter.html) still
  breaks the pipeline. Both engines support it, and multi-model
  pipelines stitch indirect edges across layers.

- [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  now stitches multi-model pipelines: pass a named list of lazy tables
  or SQL strings (one element per model) and any source table matching
  another element’s name links to that model’s node, so a
  bronze/silver/gold flow renders as one multi-hop DAG. Intermediate
  models draw as orange transform nodes, terminal models as green
  targets, and `metadata$models` records each model’s SQL and engine.

- Diagrams are laid out by a height-aware layered algorithm: each
  pipeline hop advances one column, nodes stack with spacing that
  accounts for their column count (tall tables no longer overlap), and
  layers are vertically centered.

- The ducklake vignette now ends with the stitched whole-lake diagram
  and a transitive
  [`lineage_upstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)
  impact query.

- [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  results are now classed `dplyneage_lineage` with a compact print
  method summarising engine, tables, output columns, and edge count.

- New
  [`lineage_edges()`](https://tgerke.github.io/dplyneage/reference/lineage_edges.md)
  and
  [`lineage_tables()`](https://tgerke.github.io/dplyneage/reference/lineage_tables.md)
  flatten a lineage object into plain data frames — one classified row
  per column edge, one row per table.

- Lineage edges are now classified as `identity`, `aggregation`, or
  `transformation` (mirroring OpenLineage’s transformation types) in
  both engines. Diagrams label non-identity edges with the column’s
  defining expression and animate aggregations automatically;
  [`lineage_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md)
  and
  [`lineage_graphml()`](https://tgerke.github.io/dplyneage/reference/lineage_graphml.md)
  carry the classification and expression on each edge.

- New
  [`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md)
  compares two extractions and reports added/removed edges and columns —
  extract lineage on two branches and fail CI when column provenance
  changed.

- New
  [`lineage_upstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)
  and
  [`lineage_downstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)
  answer impact questions (“what feeds this column?” / “what does this
  column feed?”) by transitive traversal, without exporting to igraph
  first.

- reticulate has moved from Imports to Suggests: dbplyr pipelines are
  analyzed entirely in R, so Python tooling is now only installed by
  users who analyze raw SQL.
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  and
  [`has_sqlglot()`](https://tgerke.github.io/dplyneage/reference/has_sqlglot.md)
  explain the requirement when reticulate is missing.

- Schema-qualified tables keep their qualifier: `stg.orders` and
  `raw.orders` are now distinct nodes in both engines instead of merging
  into one `orders` node,
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)’s
  `schema` argument accepts qualified names
  (`list("stg.orders" = ...)`), and automatic schema harvesting looks
  qualified tables up correctly.

- [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  no longer lets a real table named `output` collide with the synthetic
  output node, and sources whose table cannot be determined (`NA` or
  empty names) now connect to the `unknown` node instead of producing
  dangling edges.

- The sqlglot engine now records each output column’s actual defining
  expression (previously it recorded the column name), matching the R
  engine.

- `metadata$table_count` is now `metadata$node_count`, since it counts
  all diagram nodes including the output node.

- The static SVG fallback in
  [`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md)
  escapes table labels before inserting them into HTML.

- [`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md)
  now routes each target column’s edges through its own vertical lane
  instead of bending every edge at the same midpoint, so parallel edges
  no longer draw on top of each other. Edges fanning into the same
  target column still merge into one lane on purpose. Lanes are
  fractions of the source-to-target span, so they hold up when nodes are
  dragged.

- New vignette
  [`vignette("ducklake-lineage")`](https://tgerke.github.io/dplyneage/articles/ducklake-lineage.md)
  shows dplyneage working with
  [ducklake](https://github.com/tgerke/ducklake-r): lineage for lake
  pipelines, per-layer diagrams, and time-travel queries
  ([\#1](https://github.com/tgerke/dplyneage/issues/1)).

- New
  [`lineage_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md)
  and
  [`lineage_graphml()`](https://tgerke.github.io/dplyneage/reference/lineage_graphml.md)
  export
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  results (or hand-built node/edge lists) to interchange formats: a
  clean JSON schema for scripting, CI diffs, and data catalogs, and
  column-level GraphML that loads directly into igraph, Gephi, or yEd
  for impact analysis.

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
