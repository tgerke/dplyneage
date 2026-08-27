# lineage_check(): the CI gate over lineage_diff(). Engine-free: all
# lineages are hand-built. Every call pins `annotate` (or the
# GITHUB_ACTIONS env var) because the package's own CI runs on Actions,
# where the auto-detected default would flip the output format.

check_old <- function() {
  list(
    nodes = list(
      create_table_node("orders", c("amount", "tax")),
      create_table_node("out", "total", table_type = "target")
    ),
    edges = list(create_column_edge("orders", "amount", "out", "total"))
  )
}

test_that("an unchanged lineage passes and returns the diff invisibly", {
  expect_output(
    out <- withVisible(lineage_check(check_old(), check_old(), annotate = FALSE)),
    "no changes"
  )
  expect_false(out$visible)
  expect_s3_class(out$value, "dplyneage_lineage_diff")
  expect_false(lineage_has_changes(out$value))
})

test_that("breaking changes fail with a classed condition carrying the diff", {
  new <- check_old()
  new$edges <- list()

  cnd <- tryCatch(
    capture.output(lineage_check(check_old(), new, annotate = FALSE)),
    dplyneage_lineage_check_failure = function(cnd) cnd
  )
  expect_s3_class(cnd, "dplyneage_lineage_check_failure")
  expect_s3_class(cnd$diff, "dplyneage_lineage_diff")
  expect_identical(cnd$diff$removed_edges$severity, "breaking")

  expect_snapshot(
    lineage_check(check_old(), new, annotate = FALSE),
    error = TRUE
  )
})

test_that("fail_on = 'none' reports without failing", {
  new <- check_old()
  new$edges <- list()

  expect_snapshot(
    diff <- lineage_check(check_old(), new, fail_on = "none", annotate = FALSE)
  )
  expect_true(lineage_has_changes(diff))
})

test_that("fail_on distinguishes additions from breaking changes", {
  new <- check_old()
  new$edges <- c(
    new$edges,
    list(create_column_edge("orders", "tax", "out", "total"))
  )

  expect_output(
    lineage_check(check_old(), new, annotate = FALSE),
    "non-breaking: added edge",
    fixed = TRUE
  )
  expect_error(
    capture.output(
      lineage_check(check_old(), new, fail_on = "any", annotate = FALSE)
    ),
    class = "dplyneage_lineage_check_failure"
  )
})

test_that("annotations mark findings by whether they fail the check", {
  new <- check_old()
  new$edges <- c(
    new$edges,
    list(create_column_edge("orders", "tax", "out", "total"))
  )
  expect_output(
    lineage_check(check_old(), new, annotate = TRUE),
    "::warning::lineage: added edge orders.tax -> out.total",
    fixed = TRUE
  )

  removed <- check_old()
  removed$edges <- list()
  expect_snapshot(
    lineage_check(check_old(), removed, annotate = TRUE),
    error = TRUE
  )
})

test_that("GITHUB_ACTIONS drives the annotate default", {
  skip_if_not_installed("withr")
  new <- check_old()
  new$edges <- c(
    new$edges,
    list(create_column_edge("orders", "tax", "out", "total"))
  )

  withr::local_envvar(c(GITHUB_ACTIONS = "true"))
  expect_output(lineage_check(check_old(), new), "::warning::", fixed = TRUE)
  expect_output(
    lineage_check(check_old(), new, annotate = FALSE),
    "non-breaking: added edge",
    fixed = TRUE
  )

  withr::local_envvar(c(GITHUB_ACTIONS = ""))
  expect_output(
    lineage_check(check_old(), new),
    "non-breaking: added edge",
    fixed = TRUE
  )
})

test_that("annotation lines escape workflow-command characters", {
  old <- list(
    nodes = list(
      create_table_node("orders", "amount"),
      create_table_node("out", "share%", table_type = "target")
    ),
    edges = list(create_column_edge("orders", "amount", "out", "share%"))
  )
  new <- old
  new$edges <- list()

  expect_snapshot(lineage_check(old, new, annotate = TRUE), error = TRUE)
})

test_that("annotate must be NULL or a single logical", {
  expect_error(
    lineage_check(check_old(), check_old(), annotate = "yes"),
    "TRUE, or FALSE"
  )
})
