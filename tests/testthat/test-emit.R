# lineage_emit(): HTTP transport for OpenLineage events, tested against
# a local webfakes app that logs every request it receives

skip_if_no_emit_stack <- function() {
  testthat::skip_on_cran()
  testthat::skip_if_not_installed("httr2")
  testthat::skip_if_not_installed("webfakes")
  testthat::skip_if_not_installed("dplyr")
  testthat::skip_if_not_installed("dbplyr", "2.5.0")
}

# A backend double: logs path, auth, content type, and body of each POST
# to a file (the app runs in a subprocess, so it cannot mutate test
# state), and answers with `status`
local_ol_app <- function(status = 201L, env = parent.frame()) {
  log_file <- withr::local_tempfile(fileext = ".log", .local_envir = env)
  file.create(log_file)
  app <- webfakes::new_app()
  app$locals$log_file <- log_file
  app$locals$status <- status
  app$use(webfakes::mw_raw(type = "application/json"))
  app$post(webfakes::new_regexp("^/.*$"), function(req, res) {
    entry <- list(
      path = req$path,
      authorization = req$get_header("authorization"),
      content_type = req$get_header("content-type"),
      body = if (is.null(req$raw)) "" else rawToChar(req$raw)
    )
    cat(
      jsonlite::toJSON(entry, auto_unbox = TRUE, null = "null"),
      "\n",
      sep = "",
      file = req$app$locals$log_file,
      append = TRUE
    )
    res$set_status(req$app$locals$status)
    res$send_json(list(ok = TRUE), auto_unbox = TRUE)
  })
  process <- webfakes::local_app_process(app, .local_envir = env)
  list(url = process$url(), log = log_file)
}

read_requests <- function(backend) {
  lapply(readLines(backend$log), jsonlite::fromJSON, simplifyVector = FALSE)
}

emit_fixture <- function() {
  dbplyr::lazy_frame(customer_id = 1L, amount = 1, .name = "orders") |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE)) |>
    extract_lineage(engine = "r")
}

test_that("lineage_emit POSTs one RunEvent with auth and json body", {
  skip_if_no_emit_stack()
  backend <- local_ol_app()

  result <- lineage_emit(
    emit_fixture(),
    url = backend$url,
    run_id = "00000000-0000-4000-8000-000000000000",
    event_time = "2026-01-01T00:00:00.000Z",
    api_key = "sekrit"
  )
  expect_identical(result$status, 201L)

  requests <- read_requests(backend)
  expect_length(requests, 1L)
  expect_identical(requests[[1]]$path, "/api/v1/lineage")
  expect_identical(requests[[1]]$authorization, "Bearer sekrit")
  expect_identical(requests[[1]]$content_type, "application/json")

  event <- jsonlite::fromJSON(requests[[1]]$body, simplifyVector = FALSE)
  expect_identical(event$eventType, "COMPLETE")
  expect_identical(event$run$runId, "00000000-0000-4000-8000-000000000000")
  expect_identical(event$outputs[[1]]$name, "output")
  # The body matches what lineage_openlineage() serializes
  expect_identical(
    requests[[1]]$body,
    as.character(lineage_openlineage(
      emit_fixture(),
      run_id = "00000000-0000-4000-8000-000000000000",
      event_time = "2026-01-01T00:00:00.000Z",
      pretty = FALSE
    ))
  )
})

test_that("lineage_emit sends one request per event for static kinds", {
  skip_if_no_emit_stack()
  backend <- local_ol_app()

  silver <- dbplyr::lazy_frame(amount = 1, .name = "orders") |>
    dplyr::mutate(total = amount)
  gold <- dbplyr::lazy_frame(total = 1, .name = "silver") |>
    dplyr::mutate(big = total > 100)

  result <- lineage_emit(
    extract_lineage(list(silver = silver, gold = gold)),
    url = backend$url,
    events = "job",
    event_time = "t"
  )
  expect_identical(result$event, c(1L, 2L))

  requests <- read_requests(backend)
  expect_length(requests, 2L)
  events <- lapply(requests, function(r) {
    jsonlite::fromJSON(r$body, simplifyVector = FALSE)
  })
  expect_setequal(
    vapply(events, function(e) e$job$name, character(1)),
    c("silver", "gold")
  )
  for (e in events) {
    expect_null(e$run)
    expect_match(e$schemaURL, "JobEvent$")
  }
})

test_that("lineage_emit reads OPENLINEAGE_URL and OPENLINEAGE_API_KEY", {
  skip_if_no_emit_stack()
  backend <- local_ol_app()

  withr::local_envvar(
    OPENLINEAGE_URL = backend$url,
    OPENLINEAGE_API_KEY = "from-env"
  )
  lineage_emit(emit_fixture(), event_time = "t")

  requests <- read_requests(backend)
  expect_identical(requests[[1]]$authorization, "Bearer from-env")
})

test_that("lineage_emit requires a url", {
  skip_if_not_installed("httr2")
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")
  withr::local_envvar(OPENLINEAGE_URL = NA)
  expect_error(
    lineage_emit(emit_fixture()),
    "OPENLINEAGE_URL"
  )
})

test_that("custom endpoint and extra headers are honored", {
  skip_if_no_emit_stack()
  backend <- local_ol_app()

  lineage_emit(
    emit_fixture(),
    url = backend$url,
    event_time = "t",
    endpoint = "openlineage/api/v1/lineage",
    headers = c("x-tenant" = "pcctc")
  )

  requests <- read_requests(backend)
  expect_identical(requests[[1]]$path, "/openlineage/api/v1/lineage")
  # No api_key, no Authorization header
  expect_null(requests[[1]]$authorization)
})

test_that("an HTTP failure raises a classed condition with progress", {
  skip_if_no_emit_stack()
  backend <- local_ol_app(status = 500L)

  cnd <- tryCatch(
    lineage_emit(
      emit_fixture(),
      url = backend$url,
      events = c("run", "dataset"),
      event_time = "t"
    ),
    dplyneage_emit_failure = function(c) c
  )
  expect_s3_class(cnd, "dplyneage_emit_failure")
  expect_identical(cnd$event, 1L)
  expect_identical(cnd$status, 500L)
  expect_identical(nrow(cnd$results), 0L)
  # The failing request stopped the batch
  expect_length(read_requests(backend), 1L)
})
