# OpenLineage export: RunEvent assembly, namespaces, and facets

test_that("lineage_openlineage emits a complete RunEvent", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  lineage <- dbplyr::lazy_frame(customer_id = 1L, amount = 1, .name = "orders") |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE)) |>
    extract_lineage(engine = "r")

  json <- lineage_openlineage(
    lineage,
    run_id = "00000000-0000-4000-8000-000000000000",
    event_time = "2026-01-01T00:00:00.000Z"
  )
  event <- jsonlite::fromJSON(json, simplifyVector = FALSE)

  expect_identical(event$eventType, "COMPLETE")
  expect_identical(event$run$runId, "00000000-0000-4000-8000-000000000000")
  expect_identical(event$eventTime, "2026-01-01T00:00:00.000Z")
  expect_identical(event$inputs[[1]]$name, "orders")
  expect_identical(event$outputs[[1]]$name, "output")

  cl <- event$outputs[[1]]$facets$columnLineage$fields
  total <- cl$total$inputFields[[1]]
  expect_identical(total$name, "orders")
  expect_identical(total$field, "amount")
  expect_identical(total$transformations[[1]]$type, "DIRECT")
  expect_identical(total$transformations[[1]]$subtype, "AGGREGATION")
  expect_identical(
    total$transformations[[1]]$description,
    "sum(amount, na.rm = TRUE)"
  )
})

test_that("indirect edges land in the columnLineage dataset array", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  lineage <- dbplyr::lazy_frame(a = 1, b = 2, .name = "t1") |>
    dplyr::filter(b > 0) |>
    dplyr::select(a) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  event <- jsonlite::fromJSON(
    lineage_openlineage(lineage, run_id = "x", event_time = "t"),
    simplifyVector = FALSE
  )
  cl <- event$outputs[[1]]$facets$columnLineage

  # The filter column shapes the whole dataset, not column a's lineage
  a_fields <- vapply(
    cl$fields$a$inputFields,
    function(f) f$field,
    character(1)
  )
  expect_false("b" %in% a_fields)

  dep <- cl$dataset[[1]]
  expect_identical(dep$name, "t1")
  expect_identical(dep$field, "b")
  expect_identical(dep$transformations[[1]]$type, "INDIRECT")
  expect_identical(dep$transformations[[1]]$subtype, "FILTER")
  expect_null(dep$transformations[[1]]$description)
})

test_that("multi-model pipelines put transforms in outputs", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  silver <- dbplyr::lazy_frame(customer_id = 1L, amount = 1, .name = "orders") |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total_spent = sum(amount, na.rm = TRUE))
  gold <- dbplyr::lazy_frame(customer_id = 1L, total_spent = 1, .name = "silver") |>
    dplyr::mutate(big = total_spent > 100)

  event <- jsonlite::fromJSON(
    lineage_openlineage(
      extract_lineage(list(silver = silver, gold = gold)),
      run_id = "x", event_time = "t"
    ),
    simplifyVector = FALSE
  )

  input_names <- vapply(event$inputs, function(d) d$name, character(1))
  output_names <- vapply(event$outputs, function(d) d$name, character(1))
  expect_identical(input_names, "orders")
  expect_identical(sort(output_names), c("gold", "silver"))

  gold_cl <- Filter(function(d) d$name == "gold", event$outputs)[[1]]
  big <- gold_cl$facets$columnLineage$fields$big$inputFields[[1]]
  expect_identical(big$name, "silver")
  expect_identical(big$field, "total_spent")
})

test_that("hand-built edges carry no transformations and defaults are valid", {
  lineage <- list(
    nodes = list(
      create_table_node("orders", "amount"),
      create_table_node("totals", "total", table_type = "target"),
      create_table_node("island", "x", table_type = "target")
    ),
    edges = list(create_column_edge("orders", "amount", "totals", "total"))
  )

  event <- jsonlite::fromJSON(lineage_openlineage(lineage), simplifyVector = FALSE)

  expect_match(
    event$run$runId,
    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
  )
  expect_match(event$eventTime, "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}")

  totals <- Filter(function(d) d$name == "totals", event$outputs)[[1]]
  expect_null(totals$facets$columnLineage$fields$total$inputFields[[1]]$transformations)

  # An output with no incoming edges gets a schema facet but no (invalid,
  # empty) columnLineage facet
  island <- Filter(function(d) d$name == "island", event$outputs)[[1]]
  expect_null(island$facets$columnLineage)
  expect_identical(island$facets$schema$fields[[1]]$name, "x")
})

test_that("lineage_openlineage writes to a file and returns invisibly", {
  lineage <- list(
    nodes = list(create_table_node("orders", "amount")),
    edges = list()
  )
  path <- withr::local_tempfile(fileext = ".json")
  expect_invisible(lineage_openlineage(lineage, path = path))
  expect_identical(
    jsonlite::fromJSON(path, simplifyVector = FALSE)$eventType,
    "COMPLETE"
  )
})

test_that("lineage_openlineage leaves the caller's RNG state untouched", {
  lineage <- list(
    nodes = list(create_table_node("orders", "amount")),
    edges = list()
  )

  set.seed(42)
  expected <- runif(2)
  set.seed(42)
  invisible(lineage_openlineage(lineage))
  expect_identical(runif(2), expected)

  # Isolation must not make the run ids repeat
  run_id <- function() {
    jsonlite::fromJSON(
      lineage_openlineage(lineage),
      simplifyVector = FALSE
    )$run$runId
  }
  expect_false(identical(run_id(), run_id()))
})

# Namespaces -------------------------------------------------------------

test_that("infer_namespace returns NULL for simulated connections", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  lazy_con <- dbplyr::remote_con(dbplyr::lazy_frame(x = 1))
  expect_null(infer_namespace(lazy_con))
  # simulate_postgres() shares PqConnection's class but holds no info
  expect_null(infer_namespace(dbplyr::simulate_postgres()))
})

test_that("ol_namespace_from_info formats known drivers", {
  expect_identical(
    ol_namespace_from_info("postgres", list(host = "db.local", port = "5432")),
    "postgres://db.local:5432"
  )
  expect_identical(
    ol_namespace_from_info("mysql", list(host = "h", port = 3306L)),
    "mysql://h:3306"
  )
  expect_identical(
    ol_namespace_from_info("tsql", list(host = "h", port = 1433L)),
    "mssql://h:1433"
  )
  expect_identical(
    ol_namespace_from_info(
      "redshift",
      list(host = "c.us-east-1.redshift.amazonaws.com", port = 5439L)
    ),
    "redshift://c.us-east-1:5439"
  )
  expect_identical(
    ol_namespace_from_info(
      "snowflake",
      list(servername = "org-acct.snowflakecomputing.com")
    ),
    "snowflake://org-acct"
  )
  expect_identical(ol_namespace_from_info("bigquery", list()), "bigquery")
  expect_identical(
    ol_namespace_from_info("duckdb", list(dbname = ":memory:")),
    "duckdb"
  )
  expect_identical(
    ol_namespace_from_info("duckdb", list(dbname = "/data/warehouse.duckdb")),
    "duckdb:/data/warehouse.duckdb"
  )
  expect_identical(
    ol_namespace_from_info("sqlite", list(dbname = "/data/app.sqlite")),
    "sqlite:/data/app.sqlite"
  )

  # Missing fields and unknown dialects degrade to NULL, dbGetInfo()'s
  # NA placeholders included
  expect_null(ol_namespace_from_info("postgres", list(host = "h")))
  expect_null(ol_namespace_from_info("postgres", list(host = NA, port = NA)))
  expect_null(ol_namespace_from_info("oracle", list(host = "h", port = 1521L)))
})

test_that("infer_namespace reads a live connection", {
  skip_if_not_installed("RSQLite")
  skip_if_not_installed("DBI")

  con <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
  withr::defer(DBI::dbDisconnect(con))
  expect_identical(infer_namespace(con), "sqlite")
})

test_that("captured namespaces reach datasets and the dataSource facet", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")

  db_path <- withr::local_tempfile(fileext = ".duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "orders", data.frame(customer_id = 1L, amount = 1))

  lineage <- dplyr::tbl(con, "orders") |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE)) |>
    extract_lineage(engine = "r")

  # duckdb reports the resolved path (macOS /var -> /private/var), so
  # build the expectation from the connection, not the tempfile string
  ns <- paste0("duckdb:", DBI::dbGetInfo(con)$dbname)
  expect_identical(lineage$metadata$models$output$namespace, ns)

  event <- jsonlite::fromJSON(
    lineage_openlineage(lineage, run_id = "x", event_time = "t"),
    simplifyVector = FALSE
  )
  expect_identical(event$inputs[[1]]$namespace, ns)
  expect_identical(event$outputs[[1]]$namespace, ns)
  expect_identical(event$inputs[[1]]$facets$dataSource$name, ns)
  expect_identical(event$inputs[[1]]$facets$dataSource$uri, ns)
  # The job namespace identifies the producer, not the data store
  expect_identical(event$job$namespace, "dplyneage")
  # Column-level input references carry the dataset's namespace too
  total <- event$outputs[[1]]$facets$columnLineage$fields$total$inputFields[[1]]
  expect_identical(total$namespace, ns)
})

test_that("lineage without a captured namespace falls back to dplyneage", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  lineage <- dbplyr::lazy_frame(a = 1, .name = "t1") |>
    dplyr::mutate(b = a + 1) |>
    extract_lineage(engine = "r")

  expect_null(lineage$metadata$models$output$namespace)

  event <- jsonlite::fromJSON(
    lineage_openlineage(lineage, run_id = "x", event_time = "t"),
    simplifyVector = FALSE
  )
  expect_identical(event$inputs[[1]]$namespace, "dplyneage")
  expect_null(event$inputs[[1]]$facets$dataSource)
})

test_that("an explicit namespace overrides captured namespaces", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")

  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "orders", data.frame(amount = 1))

  lineage <- dplyr::tbl(con, "orders") |>
    dplyr::mutate(double = amount * 2) |>
    extract_lineage(engine = "r")

  event <- jsonlite::fromJSON(
    lineage_openlineage(lineage, namespace = "prod", run_id = "x", event_time = "t"),
    simplifyVector = FALSE
  )
  expect_identical(event$inputs[[1]]$namespace, "prod")
  expect_identical(event$outputs[[1]]$namespace, "prod")
  expect_identical(event$job$namespace, "prod")
})

# output_name ------------------------------------------------------------

test_that("output_name renames the synthetic output dataset", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  lineage <- dbplyr::lazy_frame(customer_id = 1L, amount = 1, .name = "orders") |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE)) |>
    extract_lineage(engine = "r")

  event <- jsonlite::fromJSON(
    lineage_openlineage(
      lineage,
      run_id = "x", event_time = "t",
      output_name = "daily_totals"
    ),
    simplifyVector = FALSE
  )
  expect_identical(event$outputs[[1]]$name, "daily_totals")
  # Edges follow the rename, sources stay put
  total <- event$outputs[[1]]$facets$columnLineage$fields$total$inputFields[[1]]
  expect_identical(total$name, "orders")
  expect_identical(event$inputs[[1]]$name, "orders")
})

test_that("output_name rejects pipelines and non-strings", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  silver <- dbplyr::lazy_frame(amount = 1, .name = "orders") |>
    dplyr::mutate(total = amount)
  gold <- dbplyr::lazy_frame(total = 1, .name = "silver") |>
    dplyr::mutate(big = total > 100)
  pipeline <- extract_lineage(list(silver = silver, gold = gold))

  expect_error(
    lineage_openlineage(pipeline, output_name = "x"),
    "already carry their model names"
  )

  single <- extract_lineage(
    dplyr::mutate(dbplyr::lazy_frame(a = 1, .name = "t1"), b = a),
    engine = "r"
  )
  expect_error(
    lineage_openlineage(single, output_name = c("a", "b")),
    "single non-empty string"
  )
})

# Facets (#7) ------------------------------------------------------------

test_that("single-model events carry sql and jobType job facets", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  lineage <- dbplyr::lazy_frame(customer_id = 1L, amount = 1, .name = "orders") |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE)) |>
    extract_lineage(engine = "r")

  event <- jsonlite::fromJSON(
    lineage_openlineage(lineage, run_id = "x", event_time = "t"),
    simplifyVector = FALSE
  )

  job_type <- event$job$facets$jobType
  expect_identical(job_type$processingType, "BATCH")
  expect_identical(job_type$integration, "DPLYNEAGE")
  expect_identical(job_type$jobType, "QUERY")

  sql <- event$job$facets$sql
  expect_identical(sql$query, lineage$metadata$models$output$sql)
  expect_identical(sql$dialect, lineage$metadata$models$output$dialect)
  expect_match(sql$`_schemaURL`, "SQLJobFacet.json#/\\$defs/SQLJobFacet$")
})

test_that("multi-model events omit the sql facet but keep jobType", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  silver <- dbplyr::lazy_frame(amount = 1, .name = "orders") |>
    dplyr::mutate(total = amount)
  gold <- dbplyr::lazy_frame(total = 1, .name = "silver") |>
    dplyr::mutate(big = total > 100)

  event <- jsonlite::fromJSON(
    lineage_openlineage(
      extract_lineage(list(silver = silver, gold = gold)),
      run_id = "x", event_time = "t"
    ),
    simplifyVector = FALSE
  )
  expect_null(event$job$facets$sql)
  expect_identical(event$job$facets$jobType$integration, "DPLYNEAGE")
})

test_that("event_type is recorded and validated", {
  lineage <- list(
    nodes = list(create_table_node("orders", "amount")),
    edges = list()
  )

  event <- jsonlite::fromJSON(
    lineage_openlineage(lineage, event_type = "START"),
    simplifyVector = FALSE
  )
  expect_identical(event$eventType, "START")
  expect_match(event$schemaURL, "OpenLineage.json#/\\$defs/RunEvent$")

  expect_error(
    lineage_openlineage(lineage, event_type = "DONE"),
    "'arg' should be one of"
  )
})

test_that("nominal_time and parent become run facets", {
  lineage <- list(
    nodes = list(create_table_node("orders", "amount")),
    edges = list()
  )

  event <- jsonlite::fromJSON(
    lineage_openlineage(
      lineage,
      run_id = "x", event_time = "t",
      nominal_time = c("2026-01-01T00:00:00Z", "2026-01-01T01:00:00Z"),
      parent = list(
        run_id = "11111111-1111-4111-8111-111111111111",
        job_name = "nightly_dag"
      )
    ),
    simplifyVector = FALSE
  )

  nominal <- event$run$facets$nominalTime
  expect_identical(nominal$nominalStartTime, "2026-01-01T00:00:00Z")
  expect_identical(nominal$nominalEndTime, "2026-01-01T01:00:00Z")

  parent <- event$run$facets$parent
  expect_identical(parent$run$runId, "11111111-1111-4111-8111-111111111111")
  expect_identical(parent$job$name, "nightly_dag")
  expect_identical(parent$job$namespace, "dplyneage")

  # No arguments, no run facets key at all
  bare <- jsonlite::fromJSON(
    lineage_openlineage(lineage, run_id = "x", event_time = "t"),
    simplifyVector = FALSE
  )
  expect_null(bare$run$facets)

  expect_error(
    lineage_openlineage(lineage, nominal_time = 42),
    "ISO-8601"
  )
  expect_error(
    lineage_openlineage(lineage, parent = list(run_id = "x")),
    "run_id and job_name"
  )
})

test_that("schema facet fields carry types from a typed schema argument", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  lineage <- dbplyr::lazy_frame(customer_id = 1L, amount = 1, .name = "orders") |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE)) |>
    extract_lineage(
      engine = "r",
      schema = list(orders = list(customer_id = "INTEGER", amount = "DOUBLE"))
    )

  event <- jsonlite::fromJSON(
    lineage_openlineage(lineage, run_id = "x", event_time = "t"),
    simplifyVector = FALSE
  )
  fields <- event$inputs[[1]]$facets$schema$fields
  by_name <- stats::setNames(fields, vapply(fields, `[[`, character(1), "name"))
  expect_identical(by_name$amount$type, "DOUBLE")
  expect_identical(by_name$customer_id$type, "INTEGER")
  expect_match(
    event$inputs[[1]]$facets$schema$`_schemaURL`,
    "1-2-0/SchemaDatasetFacet.json#/\\$defs/SchemaDatasetFacet$"
  )
  # Output columns have no captured types
  out_fields <- event$outputs[[1]]$facets$schema$fields
  expect_null(out_fields[[1]]$type)

  # The same types reach the lineage_json artifact
  doc <- jsonlite::fromJSON(lineage_json(lineage), simplifyVector = FALSE)
  orders <- Filter(function(n) n$id == "orders", doc$nodes)[[1]]
  expect_identical(orders$types$amount, "DOUBLE")
})

test_that("a dataset-array-only columnLineage facet keeps an empty fields object", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  # The output column is a constant: no direct lineage, only the filter's
  # dataset-level dependency
  lineage <- dbplyr::lazy_frame(a = 1, b = 2, .name = "t1") |>
    dplyr::filter(b > 0) |>
    dplyr::transmute(flag = 1) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  json <- lineage_openlineage(
    lineage,
    run_id = "x", event_time = "t", pretty = FALSE
  )
  event <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  cl <- event$outputs[[1]]$facets$columnLineage
  expect_identical(length(cl$fields), 0L)
  expect_match(json, "\"fields\":{}", fixed = TRUE)
  expect_identical(cl$dataset[[1]]$field, "b")
})

test_that("multiple indirect kinds merge into one dataset array entry", {
  # extract_lineage() dedups indirect edges per column pair, so two kinds
  # on one source column only arise on hand-built (or future) graphs
  filter_edge <- create_column_edge("t1", "b", "out", "x")
  filter_edge$data <- list(transformation = "filter")
  sort_edge <- create_column_edge("t1", "b", "out", "y")
  sort_edge$data <- list(transformation = "sort")

  lineage <- list(
    nodes = list(
      create_table_node("t1", c("a", "b")),
      create_table_node("out", c("x", "y"), table_type = "target")
    ),
    edges = list(filter_edge, sort_edge)
  )

  event <- jsonlite::fromJSON(
    lineage_openlineage(lineage, run_id = "x", event_time = "t"),
    simplifyVector = FALSE
  )
  deps <- event$outputs[[1]]$facets$columnLineage$dataset
  expect_length(deps, 1L)
  expect_identical(deps[[1]]$field, "b")
  subtypes <- vapply(
    deps[[1]]$transformations,
    function(t) t$subtype,
    character(1)
  )
  expect_setequal(subtypes, c("FILTER", "SORT"))
})

# Static events (#8) -----------------------------------------------------

test_that("events = 'job' emits one run-less JobEvent per model", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  silver <- dbplyr::lazy_frame(customer_id = 1L, amount = 1, .name = "orders") |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total_spent = sum(amount, na.rm = TRUE))
  gold <- dbplyr::lazy_frame(customer_id = 1L, total_spent = 1, .name = "silver") |>
    dplyr::mutate(big = total_spent > 100)
  pipeline <- extract_lineage(list(silver = silver, gold = gold))

  ndjson <- lineage_openlineage(
    pipeline,
    events = "job", event_time = "t", pretty = FALSE
  )
  lines <- strsplit(ndjson, "\n", fixed = TRUE)[[1]]
  expect_length(lines, 2L)

  events <- lapply(lines, jsonlite::fromJSON, simplifyVector = FALSE)
  names(events) <- vapply(events, function(e) e$job$name, character(1))
  expect_setequal(names(events), c("silver", "gold"))

  for (e in events) {
    expect_null(e$run)
    expect_null(e$eventType)
    expect_match(e$schemaURL, "#/\\$defs/JobEvent$")
    expect_identical(e$eventTime, "t")
    # Each JobEvent carries its own model's sql facet
    expect_identical(
      e$job$facets$sql$query,
      pipeline$metadata$models[[e$job$name]]$sql
    )
  }

  gold_inputs <- vapply(
    events$gold$inputs,
    function(d) d$name,
    character(1)
  )
  expect_identical(gold_inputs, "silver")
  expect_identical(events$gold$outputs[[1]]$name, "gold")
  big <- events$gold$outputs[[1]]$facets$columnLineage$fields$big
  expect_identical(big$inputFields[[1]]$name, "silver")

  silver_inputs <- vapply(
    events$silver$inputs,
    function(d) d$name,
    character(1)
  )
  expect_identical(silver_inputs, "orders")
})

test_that("events = 'dataset' emits one run-less DatasetEvent per node", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  lineage <- dbplyr::lazy_frame(customer_id = 1L, amount = 1, .name = "orders") |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE)) |>
    extract_lineage(engine = "r")

  ndjson <- lineage_openlineage(
    lineage,
    events = "dataset", event_time = "t", pretty = FALSE
  )
  lines <- strsplit(ndjson, "\n", fixed = TRUE)[[1]]
  expect_length(lines, 2L)

  events <- lapply(lines, jsonlite::fromJSON, simplifyVector = FALSE)
  names(events) <- vapply(events, function(e) e$dataset$name, character(1))
  expect_setequal(names(events), c("orders", "output"))

  for (e in events) {
    expect_null(e$run)
    expect_null(e$job)
    expect_match(e$schemaURL, "#/\\$defs/DatasetEvent$")
  }
  # Sources register schema only; outputs carry their column lineage
  expect_null(events$orders$dataset$facets$columnLineage)
  expect_setequal(
    vapply(
      events$orders$dataset$facets$schema$fields,
      `[[`, character(1), "name"
    ),
    c("customer_id", "amount")
  )
  expect_identical(
    events$output$dataset$facets$columnLineage$fields$total$inputFields[[1]]$field,
    "amount"
  )
})

test_that("static job events need extraction metadata", {
  lineage <- list(
    nodes = list(
      create_table_node("orders", "amount"),
      create_table_node("totals", "total", table_type = "target")
    ),
    edges = list(create_column_edge("orders", "amount", "totals", "total"))
  )
  expect_error(
    lineage_openlineage(lineage, events = "job"),
    "metadata"
  )
  # DatasetEvents work without metadata
  expect_match(
    lineage_openlineage(lineage, events = "dataset", pretty = FALSE),
    "DatasetEvent"
  )
})

test_that("a single selected event honors pretty; NDJSON otherwise", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  lineage <- dbplyr::lazy_frame(a = 1, .name = "t1") |>
    dplyr::mutate(b = a + 1) |>
    extract_lineage(engine = "r")

  # One JobEvent, pretty: an indented single document
  json <- lineage_openlineage(lineage, events = "job", event_time = "t")
  expect_match(json, "^\\{\n")
  expect_match(json, "#/\\$defs/JobEvent")

  # pretty = FALSE is always NDJSON, even for one event
  one_line <- lineage_openlineage(
    lineage,
    events = "job", event_time = "t", pretty = FALSE
  )
  expect_false(grepl("\n", one_line, fixed = TRUE))
  expect_identical(
    jsonlite::fromJSON(one_line, simplifyVector = FALSE)$job$name,
    "output"
  )

  # Kinds combine, in kind order: run, then job, then two datasets
  ndjson <- lineage_openlineage(
    lineage,
    events = c("run", "job", "dataset"),
    run_id = "x", event_time = "t", pretty = FALSE
  )
  lines <- strsplit(ndjson, "\n", fixed = TRUE)[[1]]
  expect_length(lines, 4L)
  kinds <- vapply(lines, function(l) {
    sub("^.*#/\\$defs/", "", jsonlite::fromJSON(l, simplifyVector = FALSE)$schemaURL)
  }, character(1), USE.NAMES = FALSE)
  expect_identical(
    kinds,
    c("RunEvent", "JobEvent", "DatasetEvent", "DatasetEvent")
  )
})

test_that("output_name flows through to static job events", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  lineage <- dbplyr::lazy_frame(a = 1, .name = "t1") |>
    dplyr::mutate(b = a + 1) |>
    extract_lineage(engine = "r")

  event <- jsonlite::fromJSON(
    lineage_openlineage(
      lineage,
      events = "job", event_time = "t", output_name = "enriched",
      pretty = FALSE
    ),
    simplifyVector = FALSE
  )
  expect_identical(event$job$name, "enriched")
  expect_identical(event$outputs[[1]]$name, "enriched")
})
