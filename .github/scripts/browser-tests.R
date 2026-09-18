# Runs tests/browser for CI and fails on skips as well as failures. There a
# skip means Chrome or a fixture dependency went missing, and it would
# otherwise pass quietly with less coverage.
#
# Usage, from the package root: Rscript .github/scripts/browser-tests.R

pkgload::load_all(quiet = TRUE)
df_results <- as.data.frame(
  testthat::test_dir("tests/browser", package = "dplyneage", stop_on_failure = TRUE)
)

if (any(df_results$skipped)) {
  stop(
    "Browser tests were skipped: ",
    paste(unique(df_results$test[df_results$skipped]), collapse = "; "),
    call. = FALSE
  )
}
