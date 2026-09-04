# Lineage checks in CI

A refactor can change where a column’s numbers come from without
changing the code’s shape at all: swap a
[`sum()`](https://rdrr.io/r/base/sum.html) for a
[`mean()`](https://rdrr.io/r/base/mean.html), point a join at a
different table, drop an input nobody remembers. The pipeline still
runs. The dashboard still fills in. The numbers mean something else now.

[`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md)
turns that class of change into a failed pull request. It diffs two
lineage extractions, classifies each change as breaking or non-breaking,
and errors when a change crosses the threshold you set. On a GitHub
Actions runner the findings also become `::error` and `::warning`
annotations, so they show up on the PR itself.

The severity rule comes from
[`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md):
a removed or changed edge is breaking when its target column feeds
anything downstream, or lives in a target table, since those columns are
what reports and dashboards consume. Pure additions are non-breaking.
Details are in
[`?lineage_diff`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md).

## Trying it locally

No database needed:
[`dbplyr::tbl_lazy()`](https://dbplyr.tidyverse.org/reference/tbl_lazy.html)
makes a data frame traceable as if it were a warehouse table. Version
one of a pipeline:

``` r

library(dplyneage)
library(dplyr)

orders <- dbplyr::tbl_lazy(
  data.frame(order_id = 1L, customer_id = 1L, amount = 9.99),
  name = "orders"
)

v1 <- orders |>
  group_by(customer_id) |>
  summarise(total_spent = sum(amount, na.rm = TRUE))

old <- extract_lineage(v1)
```

A branch that adds a column passes, because additions can’t invalidate
anything already consuming the output:

``` r

v2 <- orders |>
  group_by(customer_id) |>
  summarise(
    total_spent = sum(amount, na.rm = TRUE),
    max_amount = max(amount, na.rm = TRUE)
  )

lineage_check(old, extract_lineage(v2), annotate = FALSE)
#>   non-breaking: added edge orders.amount -> output.max_amount
#>   non-breaking: added column output.max_amount
#> Lineage check passed: 2 changes, 0 breaking.
```

A branch that quietly redefines `total_spent` does not:

``` r

v3 <- orders |>
  group_by(customer_id) |>
  summarise(total_spent = mean(amount, na.rm = TRUE))

lineage_check(old, extract_lineage(v3), annotate = FALSE)
#>   breaking: changed edge orders.amount -> output.total_spent: sum(amount, na.rm = TRUE) => mean(amount, na.rm = TRUE)
#> Error:
#> ! Lineage check failed: 1 breaking lineage change (1 total). Inspect with lineage_diff(old, new); fail_on = "none" reports without failing.
```

We pass `annotate = FALSE` here because this article is itself rendered
on an Actions runner, where the default would print workflow commands
instead of plain lines. In your CI job you leave the default alone;
detection is automatic.

## The extract script

CI needs one thing from you: a script that builds your pipeline’s
lineage and returns it as its last value. Keep it in the repo, next to
the code it describes, so every branch carries its own version.

``` r

# ci/extract-lineage.R
library(dplyr)

orders <- dbplyr::tbl_lazy(
  data.frame(order_id = 1L, customer_id = 1L, amount = 9.99),
  name = "orders"
)

extract_lineage(list(
  silver_orders = orders |> filter(amount > 0),
  gold_totals = orders |>
    group_by(customer_id) |>
    summarise(total_spent = sum(amount, na.rm = TRUE))
))
```

For a real warehouse, replace the
[`tbl_lazy()`](https://dbplyr.tidyverse.org/reference/tbl_lazy.html)
frames with `tbl(con, ...)` tables. The script only builds lazy queries,
so nothing is collected and CI never pulls data.

## The Actions job

The job checks out the PR, adds a second worktree at main, runs both
copies of the extract script in one R session, and lets
[`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md)
decide. A breaking change raises the classed error, `Rscript` exits
nonzero, and the check fails.

``` yaml
name: lineage
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  lineage-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check out main for comparison
        run: |
          git fetch origin main
          git worktree add ../main-tree origin/main
      - uses: r-lib/actions/setup-r@v2
        with:
          use-public-rspm: true
      - name: Install packages
        run: Rscript -e 'install.packages(c("dplyneage", "dplyr", "dbplyr"))'
      - name: Lineage check
        run: |
          Rscript -e '
            old <- source("../main-tree/ci/extract-lineage.R", chdir = TRUE)$value
            new <- source("ci/extract-lineage.R", chdir = TRUE)$value
            dplyneage::lineage_check(old, new)
          '
```

The worktree is what lets both lineages build in one session with no
serialization step: main’s copy of the script produces `old`, the
branch’s copy produces `new`. Swap the install step for
`r-lib/actions/setup-r-dependencies` or renv if your project already
manages packages that way, and adjust the script paths to match your
layout.

## Comparing against a committed artifact

The worktree exists only to rebuild main’s lineage. If that lineage is
committed as a file instead, the job needs one extraction.
[`lineage_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md)
writes the file from the same script:

``` r

lineage_json(
  source("ci/extract-lineage.R", chdir = TRUE)$value,
  path = "ci/lineage.json"
)
```

[`lineage_from_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md)
reads it back as `old`, so the step that checks out main and the second
[`source()`](https://rdrr.io/r/base/source.html) call both drop out of
the job:

``` yaml
      - name: Lineage check
        run: |
          Rscript -e '
            old <- dplyneage::lineage_from_json("ci/lineage.json")
            new <- source("ci/extract-lineage.R", chdir = TRUE)$value
            dplyneage::lineage_check(old, new)
          '
```

The file has to track main. A workflow that runs on pushes to main,
rewrites `ci/lineage.json`, and commits the result keeps it current, the
way any generated file kept in a repository is maintained; until that
run lands, a pull request is checked against the lineage of the previous
merge. In return, the artifact documents the pipeline on its own: its
diff shows which edges changed, and `jq` can query it without R.

## Tuning the policy

`fail_on` sets the threshold. The default `"breaking"` lets additive
changes merge without ceremony. `"any"` fails on every provenance
change, which suits pipelines under regulatory review, where even an
added column should be acknowledged. `"none"` never fails and just
prints the findings, useful while you calibrate.

For custom reporting, catch the classed condition. It carries the full
diff:

``` r

tryCatch(
  lineage_check(old, new),
  dplyneage_lineage_check_failure = function(cnd) {
    write_pr_comment(format_my_way(cnd$diff))
    stop(cnd)
  }
)
```
