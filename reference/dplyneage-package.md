# dplyneage: Column Lineage Visualization for dplyr Pipelines

Implements column lineage visualizations using React Flow for dplyr and
dbplyr pipelines. Provides a tidyverse-style interface for tracking data
transformations through pipeline operations.

## See also

The two functions most users need:

- [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  traces column lineage from a dplyr/dbplyr pipeline or SQL query

- [`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md)
  renders the result as an interactive diagram

## Author

**Maintainer**: Travis Gerke <tgerke@mail.harvard.edu>

Authors:

- Travis Gerke <tgerke@mail.harvard.edu>
