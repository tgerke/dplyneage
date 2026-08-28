# dplyneage: Column Lineage Visualization for 'dplyr' Pipelines

Extracts column-level lineage from 'dplyr' and 'dbplyr' pipelines and
from SQL queries, and renders it as an interactive 'React Flow' diagram.
The same lineage is available as plain data for impact analysis, for
comparing pipeline versions (including a continuous-integration check
that fails on breaking provenance changes), and for export to JSON,
'GraphML', 'Mermaid', and 'OpenLineage' interchange formats.

## See also

The two functions most users need:

- [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  traces column lineage from a dplyr/dbplyr pipeline or SQL query

- [`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md)
  renders the result as an interactive diagram

## Author

**Maintainer**: Travis Gerke <travisgerke@gmail.com> \[copyright
holder\]

Authors:

- Travis Gerke <travisgerke@gmail.com> \[copyright holder\]

Other contributors:

- Meta Platforms, Inc. and affiliates (React and scheduler libraries
  bundled in inst/htmlwidgets/lib/reactflow) \[copyright holder\]

- xyflow GmbH (React Flow library bundled in
  inst/htmlwidgets/lib/reactflow) \[copyright holder\]
