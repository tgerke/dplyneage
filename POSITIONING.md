# Positioning

Where dplyneage sits in the column-level lineage field, and why the
roadmap looks the way it does. The README’s “How it compares” table is
the short form of this document.

Source: an August 2026 feature-completeness review of the package
against the field — a codebase audit with live reproductions, plus
surveys of the SQL lineage tools (dbt, SQLMesh, sqlglot, sqllineage,
Datafold), the OpenLineage ecosystem, and the R package ecosystem. The
review was LLM-assisted, with every load-bearing claim verified against
shipping behavior; the tiered roadmap issues (#2–#16) came out of it and
cite it. Dates matter here: SQLMesh had just moved to the Linux
Foundation and dbt’s Fusion engine was pre-GA when this was written.
Revisit the claims before repeating them.

## The niche

No maintained R package extracts column-level lineage. dtrackr documents
pipeline steps, the newer lineager tracks row provenance, and rdtLite
records execution history; two earlier column-level attempts died in
2013 and 2018. There is also no OpenLineage client for R at all. Outside
R, dataframe-API lineage is solved only for Spark — pandas has nothing
official and polars has an open feature request.

dplyneage’s angle is the dbplyr bridge: dplyr pipelines render as SQL,
so one lineage mechanism covers native R dataframe code and warehouse
queries alike. Among the surveyed tools, nothing else occupies that
position.

## Table stakes, all met

The field’s baseline for a column-level lineage tool, and where the
package stands:

- Extraction fidelity: dual engine (pure-R lazy-tree walk, sqlglot SQL
  parse), schema-aware, with a classed-condition fallback from the R
  engine to sqlglot.
- Interactive column tracing: hover-highlight and a click-to-isolate
  trace cone in the React Flow widget (#10).
- Transformation classification: identity / aggregation / transformation
  on every direct edge.
- Impact analysis:
  [`lineage_upstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)
  /
  [`lineage_downstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md),
  transitive, across stitched multi-model pipelines.
- Machine-readable artifacts: JSON (versioned), GraphML, Mermaid,
  OpenLineage.
- Free and local: no gated tiers. For contrast, dbt gates column-level
  lineage to Enterprise, with Fusion freeing it only in local dev.

## Ahead of the field

- Indirect lineage: `include_indirect = TRUE` draws filter, join, group,
  and sort columns (window ordering included, since \#5). dbt Catalog
  explicitly excludes these; sqlglot and sqllineage trace SELECT
  projections only.
- OpenLineage emission with the `transformations[]` facet: sqlglot,
  sqllineage, and dbt-colibri emit no OpenLineage at all.
- Lineage as a merge gate:
  [`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md)
  classifies every change as breaking or non-breaking by downstream
  blast radius, and
  [`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md)
  fails CI on it (#2, \#3). This is SQLMesh’s semantic-diff idea at
  dplyneage’s scale; dbt’s equivalent is paid Advanced CI.
- Column descriptions from R metadata: haven/labelled `label` attributes
  and database column comments become diagram tooltips and OpenLineage
  schema-facet descriptions, propagated along identity edges (#15). The
  propagation matches dbt Catalog; reading labels off R frames is
  something no SQL-text tool can do.

## Per-tool reference (August 2026)

- **dbt**: column-level lineage in dbt Catalog, Enterprise-gated. The
  Fusion engine (Rust, ELv2, pre-GA) brings free local lineage and live
  LSP lineage in VS Code. SELECT projections only; description
  propagation; Advanced CI is paid.
- **SQLMesh** (Linux Foundation since March 2026): free lineage UI with
  an upstream cone; semantic diff classifies changes breaking vs.
  non-breaking to scope backfills; downstream column tracking still an
  open issue.
- **sqlglot.lineage**: the ecosystem’s parsing engine. Per-column node
  DAG, 30+ dialects, SELECT-only, a Python library rather than a
  product. dplyneage bundles it as one of its two engines.
- **sqllineage**: broader DML/CTAS coverage than sqlglot.lineage,
  single-maintainer.
- **Datafold**: cloud-only, query-log-derived lineage with PR impact
  bots. A service, not a library; different category.
- **OpenLineage**: the only cross-vendor lineage interchange, at a 2026
  tipping point — Airflow emits by default, Snowflake ingests,
  DataHub/OpenMetadata/Marquez/Dataplex consume. Being the R producer is
  the package’s tier-2 aim.

## Roadmap status

- **Tier 0** (correctness from the audit) and **tier 1** (#2–#5, lineage
  as decision input: diff severity,
  [`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md) +
  CI recipe, versioned JSON schema, window parity between engines):
  shipped in 0.3.0.9000.
- **Tier 2** (#6–#9, OpenLineage producer fidelity: scheme-URI
  namespaces, sql/job/run facets and schema types, static
  DatasetEvent/JobEvent emission,
  [`lineage_emit()`](https://tgerke.github.io/dplyneage/reference/lineage_emit.md)
  over HTTP with a verified Marquez round-trip): shipped in 0.3.0.9000.
- **Tier 3** (#10–#13, visualization and API parity: click-to-trace
  cone, widget chrome — minimap, PNG export, dark mode, legend, Shiny
  input — table-level impact queries and the
  [`lineage_unused()`](https://tgerke.github.io/dplyneage/reference/lineage_unused.md)
  dead-column report, column-level SVG fallback): shipped in 0.3.0.9000.
- **Tier 4** (#14–#16): strategic bets. Label and description
  propagation shipped in 0.3.0.9000 (#15): `label` attributes and
  database column comments carried on nodes, propagated along identity
  edges, shown in widget tooltips, and emitted as OpenLineage
  schema-facet descriptions. The arrow/dtplyr/duckplyr engines (#14)
  also shipped in 0.3.0.9000: dtplyr step trees and arrow queries walked
  natively in R, duckplyr relations rendered to duckdb SQL for the
  sqlglot engine (the relation itself is opaque to R), each pinned by a
  parity suite against the dbplyr walker. That makes dplyneage the only
  column-level lineage extractor for dataframe code on four backends;
  elsewhere only Spark has one. Targets integration (#16) remains open.

## Non-goals

Orchestration, materialization and backfill scoping, BI-dashboard
lineage reach, query-log-derived lineage, and being a catalog UI. Those
belong to the platforms. The correct comparables are sqlglot.lineage and
artifact-layer tools like dbt-colibri, and dplyneage compares favorably
against that class.

## Adoption note

At the time of the review, reception — not features — was the
bottleneck: near-zero public mentions. A launch post and a verified
round-trip demo into a Marquez or DataHub quickstart would do more for
the package than any single roadmap item; tier 2’s
[`lineage_emit()`](https://tgerke.github.io/dplyneage/reference/lineage_emit.md)
is designed to double as that demo.
