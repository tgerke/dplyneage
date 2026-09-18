# 0001. Report coverage to Codecov, with informational statuses

Date: 2026-09-17. Status: accepted.

## Context

dplyneage was on CRAN at 0.3.1 and marked stable, with a three-OS R-CMD-check workflow and 17 test files, but nothing measured coverage. Three languages ship in the package: R, a Python module called through reticulate, and the widget's JavaScript. A number for R alone would overstate how much of the package is tested.

## Decision

One workflow, `.github/workflows/test-coverage.yaml`, uploads to Codecov under three flags: `r`, `python`, and `js`. `codecov.yml` turns PR comments off and makes the project and patch statuses informational. The README carries one badge for the whole project.

The R job copies the Python and sqlglot setup from `R-CMD-check.yaml` and sets `NOT_CRAN: true`. The sqlglot tests are gated by `skip_if_no_sqlglot()` in `tests/testthat/helper-lineage.R`. Without that setup they skip, and `R/sqlglot_utils.R`, the largest R file, would read as nearly untested.

The badge line in `README.md` was added by hand. Re-knitting `README.Rmd` for a one-line change had churned five PNG figures the last time, and no hook enforces that the two files stay in sync.

## Alternatives considered

Running covr in CI with no third-party service. That gives a number in a log, but no badge, no trend, and no per-file view to browse.

Blocking statuses. The maintainer commits to `main` alone, so a 0.1% dip would put a red X on a commit for no useful reason.

Pinning every action to a commit SHA. The r-lib template already pins the Codecov action that way, and that is the action that receives the token. The others use major-version tags, as `R-CMD-check.yaml` does. The upload jobs expose only `CODECOV_TOKEN` and a read-only `GITHUB_TOKEN`, which bounds the damage if the action is ever compromised, as Codecov's uploader was in 2021.

## How it was decided and checked

Proposed by an LLM coding assistant (Claude Code) in a planning step and approved by the maintainer before any file changed. The maintainer created the Codecov account link and the `CODECOV_TOKEN` secret; the assistant does not handle tokens.

A local covr baseline came first: 91.45% across 316 tests with none skipped. The first CI run on 2026-09-18 reported the same 91.45%, and Codecov showed the `r` flag at 91.44%.

## Revisit if

Other contributors start opening pull requests. A blocking patch status earns its keep then. Also revisit if Codecov changes its token rules for public repositories.
