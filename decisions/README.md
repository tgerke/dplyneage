# Decisions

Short records of choices in this repository that the code cannot explain by itself: why something was done one way when another way was available. One file per decision, numbered in the order they were made. The directory is listed in `.Rbuildignore` and does not ship with the package.

Each record has the same parts:

- Context: what prompted the decision
- Decision: what was chosen, with the file paths it touches
- Alternatives considered: what was turned down, and why
- How it was decided and checked: who proposed it, who approved it, and the evidence that it works. Several of these decisions were proposed by an LLM coding assistant and approved by the maintainer, so the record says which claims were verified and how.
- Revisit if: what would make the decision worth reopening

A record is not edited after the fact except to fix errors. If a decision changes, add a new record and mark the old one as superseded.

## Index

| No. | Decision | Date |
|---|---|---|
| [0001](0001-report-coverage-to-codecov.md) | Report coverage to Codecov, with informational statuses | 2026-09-17 |
| [0002](0002-python-coverage-from-the-r-suite.md) | Measure the Python module through the R test suite | 2026-09-17 |
| [0003](0003-node-unit-tests-for-the-widget.md) | Unit-test the widget's browser-free code with Node's test runner | 2026-09-17 |
| [0004](0004-generate-ci-config-instead-of-recalling-it.md) | Generate CI configuration instead of recalling it | 2026-09-17 |
| [0005](0005-browser-tests-with-chromote.md) | Test the rendered widget with chromote, outside `tests/testthat` | 2026-09-18 |
| [0006](0006-bundle-coverage-and-two-bundle-ci.md) | Attribute bundle coverage through a separate source-mapped build | 2026-09-18 |
| [0007](0007-readme-tracks-the-development-version.md) | The README tracks the development version, with a temporary CRAN note | 2026-09-18 |
