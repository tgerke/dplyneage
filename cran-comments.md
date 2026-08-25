## R CMD check results

0 errors | 0 warnings | 1 note

* This is a new submission.

## Bundled JavaScript

The package ships one pre-built JavaScript bundle,
`inst/htmlwidgets/lib/reactflow/reactflow-bundle.min.js`, which is what
renders the interactive lineage diagrams. It is compiled with webpack from
the sources in `srcjs/` in the GitHub repository linked from DESCRIPTION.
The bundle embeds React (Meta Platforms, Inc. and affiliates) and React
Flow (xyflow GmbH), both MIT licensed. Both copyright holders are listed
in DESCRIPTION with the `cph` role, and the terms are reproduced in
`LICENSE.note`. Minified upstream license headers are preserved next to
the bundle in `reactflow-bundle.min.js.LICENSE.txt`.

## Python and network access

Lineage for dplyr/dbplyr pipelines is computed entirely in R. Raw SQL
input is handled by the Python sqlglot library through reticulate, which
is a Suggests dependency.

Because reticulate provisions its Python environment on first use, and
that requires network access, nothing in this package starts Python during
a CRAN check. The sqlglot examples, the sqlglot tests, and the raw-SQL
chunks in `vignette("getting-started")` are all conditional on `NOT_CRAN`
being set, so they are skipped on CRAN and run in the maintainer's and CI
environments. `.onLoad()` calls `reticulate::py_require()` to declare the
sqlglot requirement, which only records it and does no I/O.

The affected chunks of `vignette("getting-started")` therefore render as
unevaluated code on CRAN. The fully rendered vignette is on the package
website, linked from DESCRIPTION.

## Test environments

* local macOS, R 4.5.2
* GitHub Actions: ubuntu-latest (devel, release, oldrel-1), macOS-latest
  (release), windows-latest (release)
* win-builder (devel and release)
