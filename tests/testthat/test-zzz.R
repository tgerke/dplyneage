# reticulate is a Suggests dependency; the sqlglot paths must degrade
# clearly when it is absent

test_that("has_sqlglot is FALSE without reticulate", {
  local_mocked_bindings(reticulate_available = function() FALSE)
  expect_false(has_sqlglot())
})

test_that("SQL input without reticulate explains the requirement", {
  local_mocked_bindings(reticulate_available = function() FALSE)
  expect_error(extract_lineage("SELECT 1"), "reticulate")
})

test_that("lineage_module errors clearly without reticulate", {
  local_mocked_bindings(reticulate_available = function() FALSE)
  # Simulate a load where .onLoad skipped the import
  old <- .dplyneage$lineage
  withr::defer(assign("lineage", old, envir = .dplyneage))
  .dplyneage$lineage <- NULL

  expect_error(lineage_module(), "reticulate")
})
