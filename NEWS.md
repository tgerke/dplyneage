# dplyneage (development version)

Correctness fixes and the feature tiers from an August 2026 audit of
the package against current column-level lineage tooling (SQLMesh,
dbt, sqlglot, OpenLineage). The remaining roadmap from the audit is
filed as tiered issues on GitHub.

* The sqlglot engine (raw SQL, the dbplyr fallback, and every duckplyr
  frame) classifies a column by the outermost hop that computes it,
  with identity hops transparent, the rule the R walkers already
  applied. A computed column read back through a wrapper (dbplyr's
  nested selects for chained `mutate()` calls, the `SELECT *` duckplyr
  adds after every later verb, a CTE selected by name) used to come out
  `identity` with the bare column as its expression, which also let
  labels and types propagate across it as if it were a passthrough.
  Set-operation branches take the strongest kind.

* Indirect columns resolve through derived tables and CTEs on the
  sqlglot engine. A `filter()`, `group_by()`, or `arrange()` on a
  column a `mutate()` computed was either skipped (the dbplyr fallback)
  or, on duckplyr, attributed to a phantom column of the base table; it
  now lands on the columns the computed one was built from. On duckplyr,
  the `___row_number` ordering helper no longer leaks as a sort source,
  bare window spellings (`mean(x) OVER`, `count_star() OVER`) classify
  as aggregations, and a `filter()` before a `mutate()` on an in-memory
  frame no longer traces every column to `*`.

* duckplyr lineage reports the frame's column names after
  `rename_with()` or `names<-`, which set names on the frame while the
  duckdb relation kept projecting the old ones. When duckplyr has run a
  verb eagerly because it cannot translate it, the error now says so
  and points at `DUCKPLYR_FALLBACK_INFO` to find the step, instead of
  suggesting the frame be re-created.

* dtplyr records grouping keys as indirect sources of a `transmute()`
  only when its expressions depend on the grouping, as the mutate step
  already did and as the other engines do.

* The mutate family is pinned by one shared table of shapes run on all
  five paths: `mutate()` in its argument forms, `transmute()`,
  `across()` with formulas, `.names`, function lists, and tidyselect
  helpers, references within one call, overwrites, conditionals,
  renames and relocates, chains through `select()`, `summarise()`, and
  `filter()`, and the windowed shapes. A shape a backend cannot run
  asserts that backend's error rather than skipping. `?extract_lineage`
  now lists what every engine traces, and the getting-started vignette
  gains a section on computed columns.

* `extract_lineage()` reads three more lazy backends. dtplyr
  `lazy_dt()` pipelines and arrow queries are walked natively in R,
  covering the translated expression forms each backend produces
  (`n()` arriving as `.N`, `case_when()` as `fcase()`, arrow's window
  workaround compiling to an aggregation self-join) and every join
  style's orientation. duckplyr frames take a different route because
  their lazy tree is an opaque duckdb relation: the engine renders the
  relation to duckdb SQL, rewrites it into a bindable form, and hands
  it to the sqlglot engine, so duckplyr lineage needs reticulate where
  dtplyr and arrow need nothing. Metadata records the engine that ran
  and a matching dialect label (`"data.table"`, `"arrow"`, `"duckdb"`);
  arrow models carry no query text, dtplyr models record the generated
  data.table call, and duckplyr models record deterministic SQL that
  diffs cleanly in CI. Nameless in-memory sources get placeholders
  (`df`, `arrow_table`, ...), so `lazy_dt(df, name = )` is worth
  passing; file-backed duckplyr readers and arrow datasets use their
  file paths, with schema-derived column types on the nodes. dtplyr
  and arrow pipelines cannot fall back to sqlglot (they compile to
  data.table code and Acero plans, not SQL), so untraceable constructs
  error with an explanation instead; duckplyr pipelines that duckplyr
  itself ran eagerly (grouped `mutate()`, `rowwise()`) come back as
  plain tibbles with no tree left, and the plain-data-frame error now
  says so. Parity suites pin each walker's edge sets and
  classifications against the dbplyr engine on shared pipelines. (#14)

* Column labels now travel through lineage. `extract_lineage()` reads
  `label` attributes from local frames (the haven/labelled convention),
  reads column comments from a live duckdb or postgres connection on
  any engine, and takes a `labels` argument
  (`list(orders = c(amount = "Order amount in USD"))`) that wins over
  both. Labels and column types then propagate along identity edges,
  the way dbt Catalog carries descriptions through passthrough columns:
  a renamed or selected-through column reports its source's metadata,
  aggregations stay bare, and a column fed conflicting values inherits
  nothing. Hovering a column in `lineage_flow()` shows a themed card
  with its type and label (native tooltips in the SVG fallback),
  `lineage_json()` adds a per-node `labels` map, and OpenLineage
  schema-facet fields gain a `description`. Note `labels` sits after
  `schema` in the signature, so positional `show_sql`/`engine`/
  `include_indirect` arguments shift by one. (#15)

* `lineage_flow()` grows its widget chrome: `theme = "dark"` (or
  `"auto"`, following the viewer's OS preference) redraws the whole
  diagram on a dark palette; `legend = TRUE` (the default) overlays a
  key for the node colors and edge styles actually present;
  `minimap = TRUE` adds a pannable overview map; and the zoom controls
  gain a button that downloads the diagram as a PNG (`export_button`).
  In Shiny, clicking a column now reports `input$<outputId>_selected`
  as a `list(table =, column =)` (`NULL` when the trace is released),
  ready for `lineage_upstream()`/`lineage_downstream()` server-side.
  Every new piece degrades by omission under a stale cached bundle,
  though `theme = "dark"` needs the current bundle to render node text
  legibly. `srcjs/package-lock.json` is now committed so bundle
  rebuilds are reproducible. (#11)

* Clicking a column in a `lineage_flow()` diagram now isolates its
  trace cone, the interaction dbt Catalog and SQLMesh converge on: the
  column's transitive upstream and downstream subgraph keeps its full
  styling while every other table, column, and edge dims. Clicking the
  column again, clicking the background, or pressing Escape releases
  the cone. Hover highlighting still works inside a cone and never
  resurrects an edge outside it. (#10)

* Two viewer fixes in `lineage_flow()`: pressing Backspace with a node
  selected no longer deletes it from the diagram (a lineage diagram
  states provenance, so viewers must not be able to edit it, matching
  the earlier `nodesConnectable` fix), and re-rendering the widget,
  as Shiny does, now unmounts the previous React tree instead of
  leaking it.

* `lineage_flow()` diagrams no longer stick at minimum zoom when the
  initial fit races the embedding page's layout. React Flow computes
  its first fit on mount, and a container measured at an interim size
  (an embedding pane still settling) passed the existing nonzero-size
  guard, clamped the viewport to minZoom, and stayed there: the
  htmlwidgets resize hook only hears window resizes, not element
  reflows. The widget now observes its own element and re-fits when
  the element's size changes, which also makes the 0.2.1 resize
  behavior work in hosts that resize elements without a window
  resize event.

* The static SVG fallback (drawn when the bundled React Flow assets
  cannot load) is now a real lineage diagram: table boxes with their
  headers, colors, and column rows; edges anchored to the columns they
  connect, dashed when indirect, with arrowheads matching each edge's
  color; and a drawing sized to the graph's bounds instead of a fixed
  800x400 frame. (#13)

* `lineage_upstream()` and `lineage_downstream()` accept a table name as
  well as a `"table.column"` string, tracing from every column of the
  table at once (the table's own columns are not part of the answer).
  Matching stays exact: names are never split on dots, and a string
  that is both a column key and a schema-qualified table id resolves as
  the column key it already was. New `lineage_unused()` reports the dead
  columns: every column on a source or transform table with no path to
  any target, which in a multi-model lineage surfaces base-table columns
  nothing reads and intermediate outputs no downstream model consumes.
  (#12)

* `lineage_openlineage()` now emits spec-faithful dataset namespaces.
  `extract_lineage()` captures an OpenLineage namespace URI from the
  table's connection while it is alive (`postgres://host:port`,
  `mysql://host:port`, `duckdb:<path>`, `sqlite:<path>`, and friends;
  in-memory databases get the bare scheme), stores it per model in the
  lineage metadata, and each dataset in the event resolves to the
  namespace of the model that referenced it, with a `dataSource` facet
  carrying the URI. The `namespace` argument default changed from
  `"dplyneage"` to `NULL`, meaning "use what was captured"; datasets
  with nothing captured (local frames, hand-built graphs) keep the old
  `"dplyneage"`, as does the job namespace, which names the producer
  rather than a data store. Passing a string still overrides everything.
  A new `output_name` argument names the synthetic `output` dataset of a
  single-query extraction after the table its result lands in. (#6)

* OpenLineage events now carry the facets catalogs actually read. The
  job gains a `jobType` facet and, for single-model lineage, a `sql`
  facet with the analyzed query and dialect. Schema facet fields
  include column types when they are known: harvested from the
  connection on the sqlglot path, or taken from a `schema` argument
  with named entries like `list(orders = list(amount = "DOUBLE"))` on
  any path; the types also appear as a `types` map on `lineage_json()`
  source nodes. New arguments: `event_type` (any spec run state, was
  hardcoded `"COMPLETE"`), `nominal_time`, and `parent` for the
  matching run facets. One placement change: indirect edges
  (filter/join/group/sort columns) move from each output column's
  `inputFields` to the `columnLineage` facet's dataset-level `dataset`
  array, which the spec defines for exactly these whole-dataset
  dependencies; consumers reading per-column `inputFields` no longer
  see them fanned out to every column. All `schemaURL`s now use the
  spec's `#/$defs/...` fragments. (#7)

* `lineage_openlineage()` can emit OpenLineage's run-less static
  events, the spec's design-time path, which is what extracting
  lineage from code without running it is. `events = "job"` produces
  one `JobEvent` per model (inputs are the datasets the model reads,
  upstream models included; each carries its own `sql` facet), and
  `events = "dataset"` one `DatasetEvent` per dataset; neither
  fabricates a run. Kinds combine, and anything beyond a single pretty
  document serializes as NDJSON, one compact event per line (the
  format `FileTransport` writes), so a committed events file can be
  replayed into any backend later. (#8)

* New `lineage_emit()` sends OpenLineage events to a backend over
  HTTP, one POST per event, with `url` and `api_key` falling back to
  the `OPENLINEAGE_URL` and `OPENLINEAGE_API_KEY` environment
  variables and failures raising a classed `dplyneage_emit_failure`
  condition. Requires the httr2 package. A new site article,
  [OpenLineage export and catalog
  round-trips](https://tgerke.github.io/dplyneage/articles/openlineage.html),
  documents the event surface and a verified round-trip into a Marquez
  quickstart, column-level lineage included. (#9)

* Indirect edges no longer lose secondary classifications. A source
  column that shapes the same output in several ways (filtered on and
  window-sorted on, say) used to keep only the first kind the engine
  emitted; the graph now records the full set on the edge. The diagram
  still draws one dashed edge and `lineage_edges()` still shows the
  first kind, but the `lineage_json()` edge gains a `transformations`
  array (additive, `format_version` stays 1) and the OpenLineage
  `columnLineage` facet's dataset array lists every kind. (#18)

* The sqlglot engine no longer counts the `ORDER BY` inside
  `WITHIN GROUP` as a result ordering. On dialects where dbplyr renders
  `median()`/`quantile()` as ordered-set aggregates, the ordered column
  drew spurious dashed `sort` edges under `include_indirect = TRUE` that
  the R engine (correctly) never drew; the column is an argument of the
  aggregate and already a direct source. Source column names from the
  sqlglot engine also no longer carry dialect quoting: tracing
  postgres-flavored SQL used to yield columns like `"amount"` with the
  quote characters embedded, breaking cross-engine agreement. (#17)

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
  [lineage checks in
  CI](https://tgerke.github.io/dplyneage/articles/lineage-ci.html),
  ships a copy-paste Actions job that diffs lineage between a pull
  request and main. (#3)

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

* The R engine now reads window partition and ordering state from the
  lazy tree, so the two engines agree on window functions. A windowed
  expression's grouping columns and its ordering columns
  (`window_order()`, ranking arguments, `order_by =`) previously
  created no edges at all; they are now direct sources of the windowed
  column, matching the `OVER` clause the sqlglot engine parses, and
  window ordering columns draw dashed `sort` edges under
  `include_indirect = TRUE`. (#5)

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

* Anything that starts Python (the sqlglot examples, the sqlglot tests,
  and the raw-SQL chunks in `vignette("getting-started")`) is now skipped
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
  later fit, including the Controls fit button, could recover it, so
  widgets on non-first Quarto revealjs slides rendered as a dot in the
  corner. No host-page JavaScript is needed anymore to work around this.

* The widget's htmlwidgets `resize` hook is now implemented: when the
  container changes size, the graph re-fits into the new frame.

* `lineage_flow(height = ...)` is respected when the widget initializes
  hidden; previously the binding overrode it with a 600px default because
  the not-yet-laid-out container measured zero.

# dplyneage 0.2.0

* `extract_lineage()` now gives a helpful error when passed a plain
  data frame, pointing to the `dbplyr::memdb_frame()` / `copy_to()`
  workaround instead of failing later with a misleading message about
  Python or SQL strings. The workaround is also documented in the README
  and on `?extract_lineage`.

* New `lineage_openlineage()` exports lineage as an OpenLineage `RunEvent`
  with `ColumnLineage` facets, the interchange format Marquez, DataHub,
  and OpenMetadata ingest, so dplyneage-extracted lineage can sit
  alongside lineage from dbt, Airflow, or Spark. Edge classifications map
  to OpenLineage transformation types, including `INDIRECT` subtypes for
  `include_indirect` edges.

* New `lineage_mermaid()` exports lineage as a Mermaid flowchart: paste
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
  `arrange()`/`ORDER BY` (which shape the result without appearing in
  it) draw as dashed edges to each output column, classified by use
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
  into plain data frames: one classified row per column edge, one row per
  table.

* Lineage edges are now classified as `identity`, `aggregation`, or
  `transformation` (mirroring OpenLineage's transformation types) in both
  engines. Diagrams label non-identity edges with the column's defining
  expression and animate aggregations automatically; `lineage_json()` and
  `lineage_graphml()` carry the classification and expression on each
  edge.

* New `lineage_diff()` compares two extractions and reports added/removed
  edges and columns: extract lineage on two branches and fail CI when
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
  that walks the pipeline's lazy query tree, no Python required. Column
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
  `reticulate::py_require()`, with no manual setup step. `install_sqlglot()`
  is deprecated and does nothing.

## Notes

* Works out of the box with any package that produces dbplyr lazy tables,
  including [ducklake](https://github.com/tgerke/ducklake-r).
* The React Flow JavaScript bundle ships pre-built with the package.
