# dplyneage (development version)

Correctness fixes and the first feature tier from an August 2026 audit
of the package against current column-level lineage tooling (SQLMesh,
dbt, sqlglot, OpenLineage). The remaining roadmap from the audit is
filed as tiered issues on GitHub.

* `lineage_diff()` now classifies every change by blast radius. Each
  element gains a `severity` column: `"breaking"` when the change's
  target column fed anything downstream in the old lineage, or sat on
  a target node, whose columns are the consumed surface;
  `"non-breaking"` for pure additions and edits to columns nothing
  consumed. All changes previously looked alike, so a CI gate could
  only fail on any change at all. The print method flags breaking
  rows. (#2)

* New `lineage_check(old, new)` turns the diff into a CI gate: one
  line per finding, a classed error
  (`dplyneage_lineage_check_failure`, threshold set by `fail_on`) when
  changes cross it, and `::error`/`::warning` annotations emitted
  automatically on GitHub Actions runners. A new site article,
  `vignette("articles/lineage-ci")`, ships a copy-paste Actions job
  that diffs lineage between a pull request and main. (#3)

* `lineage_diff()` no longer reports a phantom `NA` row when one side
  of the comparison has no edges. `paste0()` recycles zero-length
  inputs, so an empty edge frame produced the key `"."` instead of no
  keys, and the diff invented one added (or removed) edge of `NA`s.
  The same guard now covers node-free lineages and traversals.

* The `lineage_json()` document is now versioned: a top-level
  `format_version` key (currently 1) leads the artifact, bumping only
  when a change would break an existing consumer. Metadata also takes
  one shape for single queries and pipelines: both carry a `models`
  map of per-model `sql`, `engine`, and `dialect`, with a single query
  keyed by its output table. The top-level `sql` key is gone, so
  readers of a committed 0.3.0 artifact should take SQL from `models`
  instead. (#4)

* `extract_lineage()` no longer errors on `copy_inline()` frames. Their
  values are inlined into the SQL as literals, so the columns now trace
  as source-free, matching how the sqlglot engine treats `VALUES`. An
  unexpected base-table shape now signals the classed condition that
  triggers the sqlglot fallback, instead of an unclassed error that
  defeated it.

* Multi-model stitching warns when a source table resembles a model it
  did not link to. Stitching matches names exactly, so a model named
  `silver` read back as `main.silver` or `SILVER` used to render a
  silently disconnected graph with no hint why. Naming the model with
  the table's full name (`list("main.silver" = ...)`) has always
  stitched, and the warning points there.

* `lineage_diff()` now compares edge definitions, not just endpoints.
  An edge whose transformation or expression changed (say
  `sum(amount)` rewritten to `mean(amount)`) previously printed "No
  lineage changes"; it is now reported in the new `changed_edges`
  element. The new `lineage_has_changes()` answers the CI question in
  one call.

* With `include_indirect = TRUE`, raw SQL inside `filter()`,
  `group_by()`, or `arrange()` falls back to the sqlglot engine. The R
  engine cannot see the columns inside an `sql()` string and previously
  dropped such clauses without warning, losing indirect edges.

* `dialect` now defaults to `NULL`, which infers the dialect from a
  lazy table's database connection. A Postgres `tbl()` that fell back
  to sqlglot used to be parsed as `"duckdb"` unless you remembered to
  pass `dialect = "postgres"` yourself. SQL strings and unrecognized
  connections keep the `"duckdb"` default.

* `lineage_openlineage()` no longer advances the caller's RNG state.
  Run ids draw under a private seed and `.Random.seed` is restored, so
  exporting lineage mid-analysis cannot change a later `set.seed()`
  sequence's results.

* Diagrams no longer let viewers draw new edges between columns. A
  lineage diagram states provenance; a hand-drawn edge could only
  misstate it.

* Local data frames gained a lighter route: `dbplyr::tbl_lazy(df,
  name = "df")` makes a pipeline traceable with no database at all,
  which is how the package's own test suite has always run.
  `memdb_frame()` remains the route when the pipeline should also be
  collectable. The data-frame error message, README, and
  getting-started vignette now describe both.

* Removed the pre-rewrite demo scripts in `inst/examples/`, which
  still called the deleted `install_sqlglot()` and described a
  heuristic attribution design the engines replaced.

# dplyneage 0.3.0

First CRAN release. Apart from dropping a deprecated function, the work
here was packaging rather than behavior.

* dplyneage now declares `R (>= 4.1.0)`, which the examples have required
  since they started using the native pipe.

* `install_sqlglot()` is gone. It had already been reduced to a no-op that
  warned, and reticulate provisions sqlglot on its own, so there was no
  reason to carry a deprecated function into a first release.

* The ducklake integration vignette moved to a website-only article.
  ducklake is not on CRAN, so shipping it as a vignette meant declaring a
  dependency CRAN cannot resolve. The article still builds on the pkgdown
  site, and nothing about ducklake support itself changed.

* Anything that starts Python — the sqlglot examples, the sqlglot tests,
  and the raw-SQL chunks in `vignette("getting-started")` — is now skipped
  when `NOT_CRAN` is unset. reticulate provisions its environment over the
  network on first use, and CRAN checks run offline.

* The copyright and license terms of the bundled React and React Flow
  JavaScript are recorded in `LICENSE.note`, and their copyright holders
  are named in `DESCRIPTION`.

# dplyneage 0.2.1

* The pure-R engine now handles both ways dbplyr stores select
  expressions. Under dbplyr 2.5.x, partial evaluation wraps computed
  expressions in quosures and leaves `sql()` calls unevaluated, so edge
  labels picked up a leading `~` and raw-SQL columns were traced as if
  they had no sources instead of raising the classed error that triggers
  the sqlglot fallback. dbplyr 2.6.0 stores bare expressions with `sql()`
  already evaluated, which is what the engine was written against. Both
  layouts now produce identical lineage.

* `lineage_flow()` widgets that initialize while their container is hidden
  (a non-active reveal.js slide, a hidden tabset panel) now wait for the
  container to gain nonzero dimensions before mounting React Flow. Mounting
  against a zero-size container pinned the viewport at minZoom, and no
  later fit — including the Controls fit button — could recover it, so
  widgets on non-first Quarto revealjs slides rendered as a dot in the
  corner. No host-page JavaScript is needed anymore to work around this.

* The widget's htmlwidgets `resize` hook is now implemented: when the
  container changes size, the graph re-fits into the new frame.

* `lineage_flow(height = ...)` is respected when the widget initializes
  hidden; previously the binding overrode it with a 600px default because
  the not-yet-laid-out container measured zero.

# dplyneage 0.2.0

* `extract_lineage()` now gives an actionable error when passed a plain
  data frame, pointing to the `dbplyr::memdb_frame()` / `copy_to()`
  workaround instead of failing later with a misleading message about
  Python or SQL strings. The workaround is also documented in the README
  and on `?extract_lineage`.

* New `lineage_openlineage()` exports lineage as an OpenLineage `RunEvent`
  with `ColumnLineage` facets — the interchange format Marquez, DataHub,
  and OpenMetadata ingest, so dplyneage-extracted lineage can sit
  alongside lineage from dbt, Airflow, or Spark. Edge classifications map
  to OpenLineage transformation types, including `INDIRECT` subtypes for
  `include_indirect` edges.

* New `lineage_mermaid()` exports lineage as a Mermaid flowchart — paste
  it into a ` ```mermaid ` fence and it renders natively on GitHub, in
  Quarto, and in most documentation tools, with no htmlwidget involved.
  Tables draw as colored subgraphs, non-identity edges carry their
  expression, and indirect edges draw dashed.

* The getting-started vignette now covers local data frames: plain-dplyr
  pipelines have no lazy query tree to trace, and
  `dbplyr::memdb_frame()` (or any `copy_to()`) is the one-line workaround
  that makes the identical pipeline traceable.

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
