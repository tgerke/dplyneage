# dplyneage: Column Lineage Visualization for 'dplyr' Pipelines

Implements column lineage visualizations using 'React Flow' for 'dplyr'
and 'dbplyr' pipelines. Provides a tidyverse-style interface for
tracking data transformations through pipeline operations.

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
