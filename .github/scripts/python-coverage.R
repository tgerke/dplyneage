# Measures inst/python under the R test suite. The Python module is only
# ever called from R, so the R tests are its tests: coverage.py traces
# reticulate's embedded interpreter while testthat runs in this process.
#
# Usage, from the package root: Rscript .github/scripts/python-coverage.R <outfile.xml>

outfile <- commandArgs(trailingOnly = TRUE)[1]
if (is.na(outfile)) {
  stop("Usage: Rscript .github/scripts/python-coverage.R <outfile.xml>", call. = FALSE)
}

# Loading first registers the package's py_require() before Python starts
pkgload::load_all(quiet = TRUE)
reticulate::py_require("coverage")
coverage <- reticulate::import("coverage")

# No data file: the report is written straight from memory. Leave
# relative_files off: combined with an absolute include it filters every
# file out of the report, and the XML paths already come out relative to the
# working directory.
py_cov <- coverage$Coverage(
  data_file = NULL,
  include = file.path(getwd(), "inst", "python", "*"),
  config_file = FALSE
)

# The module is imported with delay_load, so starting here also catches its
# import-time lines
py_cov$start()
results <- testthat::test_local(stop_on_failure = FALSE)
py_cov$stop()

py_cov$xml_report(outfile = outfile)

df_results <- as.data.frame(results)
if (any(df_results$failed > 0 | df_results$error)) {
  stop("Tests failed during the Python coverage pass", call. = FALSE)
}
