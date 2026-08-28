# Gate a CI run on lineage changes

Compares two lineage extractions and fails when the changes cross a
severity threshold: the one-call version of "diff the lineage and stop
the merge". Findings print one per line, and on GitHub Actions they
become `::error`/`::warning` annotations on the run.

## Usage

``` r
lineage_check(
  old,
  new,
  fail_on = c("breaking", "any", "none"),
  annotate = NULL
)
```

## Arguments

- old, new:

  Lineage objects from
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  (or lists with `nodes` and `edges`), in before/after order — typically
  main's extraction and the branch's.

- fail_on:

  Which changes fail the check: `"breaking"` (the default) stops on
  breaking changes only, `"any"` stops on any change, and `"none"`
  always passes, printing findings as a report.

- annotate:

  Print findings as GitHub Actions workflow commands
  (`::error::`/`::warning::`) instead of plain lines. The default `NULL`
  turns annotations on exactly when the `GITHUB_ACTIONS` environment
  variable is `"true"`, as it is on every Actions runner.

## Value

The
[`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md)
of the two lineages, invisibly. When the check fails, the error
condition (class `"dplyneage_lineage_check_failure"`) carries the same
diff in its `diff` field.

## Details

The failure is a classed condition, so a wrapper can catch it and report
its own way:

    tryCatch(
      lineage_check(old, new),
      dplyneage_lineage_check_failure = function(cnd) post_comment(cnd$diff)
    )

The package site's [lineage checks in
CI](https://tgerke.github.io/dplyneage/articles/lineage-ci.html) article
walks through the full setup, including a GitHub Actions job that
extracts lineage on a pull request branch and on main, then fails the
merge on breaking changes.

## See also

Other lineage accessors:
[`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md),
[`lineage_edges()`](https://tgerke.github.io/dplyneage/reference/lineage_edges.md),
[`lineage_tables()`](https://tgerke.github.io/dplyneage/reference/lineage_tables.md),
[`lineage_unused()`](https://tgerke.github.io/dplyneage/reference/lineage_unused.md),
[`lineage_upstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)

## Examples

``` r
old <- list(
  nodes = list(
    create_table_node("orders", "amount"),
    create_table_node("out", "total", table_type = "target")
  ),
  edges = list(create_column_edge("orders", "amount", "out", "total"))
)
# an unchanged lineage passes
lineage_check(old, old, annotate = FALSE)
#> Lineage check passed: no changes.

# removing the edge into a target column is breaking
new <- old
new$edges <- list()
try(lineage_check(old, new, annotate = FALSE))
#>   breaking: removed edge orders.amount -> out.total
#> Error : Lineage check failed: 1 breaking lineage change (1 total). Inspect with lineage_diff(old, new); fail_on = "none" reports without failing.

# report-only mode never fails
lineage_check(old, new, fail_on = "none", annotate = FALSE)
#>   breaking: removed edge orders.amount -> out.total
#> Lineage check passed: 1 change, 1 breaking.
```
