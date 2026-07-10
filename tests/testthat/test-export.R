# Exporters run engine-free: graphs come from convert_lineage_to_graph()
# on the shared fixture, or from the manual builders

fixture_graph <- function() {
  convert_lineage_to_graph(fixture_lineage())
}

manual_graph <- function() {
  list(
    nodes = list(
      create_table_node("orders", c("order_id", "amount")),
      create_table_node("daily_totals", "total", table_type = "target")
    ),
    edges = list(
      create_column_edge("orders", "amount", "daily_totals", "total")
    )
  )
}

# JSON -------------------------------------------------------------------

test_that("lineage_json emits the semantic schema", {
  parsed <- jsonlite::fromJSON(
    lineage_json(fixture_graph()),
    simplifyVector = FALSE
  )

  expect_named(parsed, c("metadata", "nodes", "edges"))

  ids <- vapply(parsed$nodes, function(n) n$id, character(1))
  types <- vapply(parsed$nodes, function(n) n$type, character(1))
  expect_identical(sort(ids), c("customers", "orders", "output"))
  expect_identical(types[ids == "output"], "target")

  output_cols <- parsed$nodes[[which(ids == "output")]]$columns
  expect_identical(
    sort(unlist(output_cols)),
    c("customer_id", "total_spent")
  )

  expect_length(parsed$edges, 2L)
  expect_named(
    parsed$edges[[1]],
    c(
      "source", "source_column", "target", "target_column",
      "transformation", "expression"
    )
  )
  amount_edge <- Filter(function(e) e$source_column == "amount", parsed$edges)
  expect_identical(amount_edge[[1]]$source, "orders")
  expect_identical(amount_edge[[1]]$target, "output")
  expect_identical(amount_edge[[1]]$target_column, "total_spent")
  expect_identical(amount_edge[[1]]$transformation, "aggregation")
  expect_identical(amount_edge[[1]]$expression, "SUM(amount)")
})

test_that("hand-built edges export without transformation fields", {
  parsed <- jsonlite::fromJSON(
    lineage_json(manual_graph()),
    simplifyVector = FALSE
  )

  expect_named(
    parsed$edges[[1]],
    c("source", "source_column", "target", "target_column")
  )
})

test_that("lineage_json passes metadata through", {
  parsed <- jsonlite::fromJSON(
    lineage_json(fixture_graph()),
    simplifyVector = FALSE
  )

  expect_identical(parsed$metadata$sql, "SELECT ...")
  expect_identical(parsed$metadata$dialect, "duckdb")
  expect_identical(parsed$metadata$engine, "sqlglot")
  expect_identical(parsed$metadata$edge_count, 2L)
})

test_that("single-column nodes serialize columns as a JSON array", {
  parsed <- jsonlite::fromJSON(
    lineage_json(fixture_graph()),
    simplifyVector = FALSE
  )

  ids <- vapply(parsed$nodes, function(n) n$id, character(1))
  customers_cols <- parsed$nodes[[which(ids == "customers")]]$columns
  # with simplifyVector = FALSE a JSON array parses to a list; a bare
  # string (the auto_unbox collapse this guards against) would not
  expect_type(customers_cols, "list")
  expect_identical(customers_cols[[1]], "customer_id")
})

test_that("pretty = FALSE produces a single line", {
  out <- lineage_json(fixture_graph(), pretty = FALSE)
  expect_length(out, 1L)
  expect_false(grepl("\n", out))
})

test_that("lineage_json writes to path and returns invisibly", {
  path <- withr::local_tempfile(fileext = ".json")

  expect_invisible(lineage_json(fixture_graph(), path = path))
  written <- paste(readLines(path), collapse = "\n")
  expect_identical(written, as.character(lineage_json(fixture_graph())))
})

test_that("manual node/edge lists export without a metadata key", {
  parsed <- jsonlite::fromJSON(
    lineage_json(manual_graph()),
    simplifyVector = FALSE
  )

  expect_named(parsed, c("nodes", "edges"))
  expect_identical(parsed$edges[[1]]$source, "orders")
  expect_identical(parsed$edges[[1]]$target_column, "total")
})

test_that("edge-free lineage still exports", {
  lineage <- fixture_lineage()
  lineage$columns[[1]]$sources <- list()
  lineage$columns[[2]]$sources <- list()
  graph <- convert_lineage_to_graph(lineage)

  parsed <- jsonlite::fromJSON(lineage_json(graph), simplifyVector = FALSE)
  expect_length(parsed$edges, 0L)
  expect_identical(parsed$nodes[[1]]$id, "output")
})

test_that("exporters reject objects without nodes and edges", {
  expect_snapshot(error = TRUE, lineage_json(list()))
  expect_snapshot(error = TRUE, lineage_graphml(mtcars))
})

# GraphML ----------------------------------------------------------------

test_that("lineage_graphml emits valid column-level GraphML", {
  skip_if_not_installed("xml2")

  graph <- fixture_graph()
  doc <- xml2::read_xml(lineage_graphml(graph))

  ns <- unlist(xml2::xml_ns(doc))
  expect_identical(
    unname(ns["d1"]),
    "http://graphml.graphdrawing.org/xmlns"
  )

  xml2::xml_ns_strip(doc)
  keys <- xml2::xml_attr(xml2::xml_find_all(doc, "//key"), "attr.name")
  expect_identical(
    keys,
    c("name", "table", "column", "node_type", "transformation", "expression")
  )

  expect_identical(
    xml2::xml_attr(xml2::xml_find_first(doc, "//graph"), "edgedefault"),
    "directed"
  )

  # one GraphML node per (table, column) pair
  total_columns <- sum(vapply(
    graph$nodes,
    function(n) length(unlist(n$data$columns)),
    integer(1)
  ))
  nodes <- xml2::xml_find_all(doc, "//node")
  expect_length(nodes, total_columns)
  expect_length(xml2::xml_find_all(doc, "//edge"), length(graph$edges))

  ids <- xml2::xml_attr(nodes, "id")
  expect_in(
    c("customers.customer_id", "orders.amount", "output.total_spent"),
    ids
  )

  amount_edge <- xml2::xml_find_first(
    doc,
    "//edge[@source='orders.amount']"
  )
  expect_identical(xml2::xml_attr(amount_edge, "target"), "output.total_spent")
  expect_identical(
    xml2::xml_text(
      xml2::xml_find_first(amount_edge, "./data[@key='transformation']")
    ),
    "aggregation"
  )
  expect_identical(
    xml2::xml_text(
      xml2::xml_find_first(amount_edge, "./data[@key='expression']")
    ),
    "SUM(amount)"
  )

  amount_node <- xml2::xml_find_first(doc, "//node[@id='orders.amount']")
  data_vals <- xml2::xml_text(xml2::xml_find_all(amount_node, "./data"))
  expect_identical(data_vals, c("orders.amount", "orders", "amount", "source"))
})

test_that("special characters in names are escaped", {
  skip_if_not_installed("xml2")

  hostile_table <- "a<b>&\"c'"
  hostile_column <- "x&y"
  lineage <- list(
    nodes = list(
      create_table_node(hostile_table, hostile_column),
      create_table_node("out", "z", table_type = "target")
    ),
    edges = list(
      create_column_edge(hostile_table, hostile_column, "out", "z")
    )
  )

  doc <- xml2::read_xml(lineage_graphml(lineage))
  xml2::xml_ns_strip(doc)

  node <- xml2::xml_find_first(doc, "//node")
  expect_identical(
    xml2::xml_attr(node, "id"),
    paste0(hostile_table, ".", hostile_column)
  )
  expect_identical(
    xml2::xml_text(xml2::xml_find_all(node, "./data")),
    c(
      paste0(hostile_table, ".", hostile_column),
      hostile_table, hostile_column, "source"
    )
  )
  edge <- xml2::xml_find_first(doc, "//edge")
  expect_identical(
    xml2::xml_attr(edge, "source"),
    paste0(hostile_table, ".", hostile_column)
  )
})

test_that("lineage_graphml writes to path and returns invisibly", {
  skip_if_not_installed("xml2")
  path <- withr::local_tempfile(fileext = ".graphml")

  expect_invisible(lineage_graphml(fixture_graph(), path = path))
  doc <- xml2::read_xml(path)
  xml2::xml_ns_strip(doc)
  expect_length(xml2::xml_find_all(doc, "//edge"), 2L)
})

test_that("GraphML round-trips through igraph with usable names", {
  skip_if_not_installed("igraph")
  path <- withr::local_tempfile(fileext = ".graphml")
  lineage_graphml(fixture_graph(), path = path)

  g <- igraph::read_graph(path, format = "graphml")

  expect_equal(igraph::vcount(g), 4)
  expect_equal(igraph::ecount(g), 2)
  expect_in(
    c("name", "table", "column", "node_type"),
    igraph::vertex_attr_names(g)
  )

  # the payoff: ancestry of an output column in one call
  upstream <- igraph::subcomponent(g, "output.total_spent", mode = "in")
  expect_in("orders.amount", names(upstream))
  expect_false("customers.customer_id" %in% names(upstream))
})

test_that("indirect edges export their kind without an expression", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  lineage <- dbplyr::lazy_frame(a = 1, b = 2, .name = "t1") |>
    dplyr::filter(b > 0) |>
    dplyr::select(a) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  parsed <- jsonlite::fromJSON(lineage_json(lineage), simplifyVector = FALSE)
  indirect <- Filter(
    function(e) identical(e$transformation, "filter"),
    parsed$edges
  )
  expect_length(indirect, 1L)
  expect_null(indirect[[1]]$expression)

  xml <- lineage_graphml(lineage)
  expect_match(xml, '<data key="transformation">filter</data>', fixed = TRUE)
  parsed_xml <- xml2::read_xml(xml)
  expect_s3_class(parsed_xml, "xml_document")
})

# lineage_mermaid --------------------------------------------------------

test_that("lineage_mermaid renders subgraphs, edges, and classes", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  lineage <- dbplyr::lazy_frame(customer_id = 1L, amount = 1, .name = "orders") |>
    dplyr::group_by(customer_id) |>
    dplyr::summarise(total = sum(amount, na.rm = TRUE)) |>
    extract_lineage(engine = "r")

  expect_snapshot(cat(lineage_mermaid(lineage)))
})

test_that("mermaid labels non-identity edges and dashes indirect ones", {
  skip_if_not_installed("dplyr")
  skip_if_not_installed("dbplyr", "2.5.0")

  lineage <- dbplyr::lazy_frame(a = 1, b = 2, .name = "t1") |>
    dplyr::filter(b > 0) |>
    dplyr::transmute(doubled = a * 2) |>
    extract_lineage(engine = "r", include_indirect = TRUE)

  mermaid <- lineage_mermaid(lineage)
  expect_match(mermaid, 't1_a -->|"a * 2"| output_doubled', fixed = TRUE)
  expect_match(mermaid, "t1_b -.-> output_doubled", fixed = TRUE)
})

test_that("mermaid ids avoid reserved words, digits, and collisions", {
  lineage <- list(
    nodes = list(
      create_table_node("or\"ders", c("end", "1col"), table_type = "source"),
      create_table_node("out", "x", table_type = "target")
    ),
    edges = list(create_column_edge("or\"ders", "end", "out", "x"))
  )

  mermaid <- lineage_mermaid(lineage)
  # quotes become the #quot; entity, never raw inside a label
  expect_match(mermaid, 'or_ders["or#quot;ders"]', fixed = TRUE)
  expect_match(mermaid, "or_ders_end", fixed = TRUE)

  # a table named "end" would break the flowchart as a bare id, and names
  # that sanitize to the same string must stay distinct
  ids <- mermaid_id_map(c("t\rend", "t\ra.b", "t\ra_b", "t\r1col"))
  expect_identical(ids[["t\rend"]], "end_")
  expect_false(identical(ids[["t\ra.b"]], ids[["t\ra_b"]]))
  expect_identical(ids[["t\r1col"]], "n1col")
})

test_that("lineage_mermaid writes to a file and returns invisibly", {
  lineage <- list(
    nodes = list(create_table_node("orders", "amount")),
    edges = list()
  )
  path <- withr::local_tempfile(fileext = ".mmd")
  expect_invisible(lineage_mermaid(lineage, path = path))
  expect_match(readLines(path)[[1]], "flowchart LR", fixed = TRUE)
})

# lineage_openlineage ----------------------------------------------------

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

test_that("indirect edges map to INDIRECT transformation subtypes", {
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
  inputs <- event$outputs[[1]]$facets$columnLineage$fields$a$inputFields
  filter_input <- Filter(function(f) f$field == "b", inputs)[[1]]
  expect_identical(filter_input$transformations[[1]]$type, "INDIRECT")
  expect_identical(filter_input$transformations[[1]]$subtype, "FILTER")
  expect_null(filter_input$transformations[[1]]$description)
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
