# 0002. Measure the Python module through the R test suite

Date: 2026-09-17. Status: accepted.

## Context

`inst/python/dplyneage_lineage.py` does the SQL parsing behind `extract_lineage()`. It has no pytest suite, and nothing calls it except R, through reticulate. The R tests for SQL lineage and for the dbplyr integration already exercise it, so the module is tested already, from R.

## Decision

`.github/scripts/python-coverage.R` loads the package, starts coverage.py inside reticulate's embedded interpreter, runs `testthat::test_local()` in the same process, and writes a Cobertura report. CI runs it as a second pass of the suite and uploads the result under the `python` flag. The script lives under `.github/`, so nothing new ships in the package.

Two details that are easy to get wrong:

- Coverage starts before the tests. The package imports the module with `delay_load = TRUE`, so starting first also counts the module's import-time lines.
- `relative_files` stays off. Combined with an absolute `include` pattern it filters every file out of the report, and coverage.py answers "No data to report". The report's paths already come out relative to the working directory.

## Alternatives considered

A pytest suite. It would repeat assertions the R tests already make, in a second language, for a module with one caller.

Collecting Python coverage during the covr run. The package is installed to a temporary directory there, so the report would need its paths remapped back to `inst/python`. A separate pass under `load_all` needs no remapping, at the cost of running the suite twice.

## How it was decided and checked

Proposed by the assistant and approved by the maintainer. Running coverage.py inside an interpreter embedded by reticulate is unusual, and the assistant said so before relying on it. A spike confirmed that the tracer survives across separate calls from R (CTracer, Python 3.12, coverage.py 7.16) before the script was written. The first full run failed with "No data to report", which a bisect traced to `relative_files`.

Local result: 90.15%, with the full suite green. In CI the pass ran 1,894 checks with none skipped, and Codecov showed the `python` flag at 90.14%.

## Revisit if

The module gains a caller other than R, or grows logic that the R tests cannot reach cheaply. Either would justify pytest.
