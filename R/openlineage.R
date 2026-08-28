#' Export lineage as an OpenLineage run event
#'
#' Serializes a lineage object to an
#' [OpenLineage](https://openlineage.io/) `RunEvent` JSON document with a
#' `ColumnLineage` facet on each output dataset — the interchange format
#' that data catalogs and lineage backends (Marquez, DataHub,
#' OpenMetadata, ...) ingest. POST the document to an OpenLineage endpoint
#' and dplyneage-extracted lineage appears alongside lineage from dbt,
#' Airflow, or Spark.
#'
#' Source tables become the event's `inputs` (with a schema facet listing
#' their referenced columns); transform and target tables become
#' `outputs`, each carrying a `columnLineage` facet that maps every output
#' column to its input fields. Edge classifications translate to
#' OpenLineage transformation types: `identity`/`transformation`/
#' `aggregation` edges become `DIRECT` transformations with the matching
#' subtype, and indirect edges (from
#' `extract_lineage(include_indirect = TRUE)`) become `INDIRECT` with
#' subtype `FILTER`, `JOIN`, `GROUP_BY`, or `SORT`. A direct edge's
#' defining expression is carried in the transformation's `description`.
#'
#' @section Namespaces:
#' OpenLineage groups datasets by namespace, and catalogs join events to
#' known datasets through it, so the spec expects scheme URIs derived
#' from the data store (`postgres://host:port`, `mysql://host:port`).
#' [extract_lineage()] captures that URI from the table's live connection
#' — `duckdb:<path>` and `sqlite:<path>` for file-backed databases (bare
#' `duckdb`/`sqlite` in memory, since the spec names no convention for
#' either), the spec's host:port form for server databases — and each
#' dataset in the event uses the namespace captured for its model. A
#' URI-shaped namespace is also recorded in the dataset's `dataSource`
#' facet. Where nothing was captured (local frames via
#' [dbplyr::tbl_lazy()], hand-built graphs, unrecognized drivers),
#' datasets fall back to `"dplyneage"`. The job namespace is always
#' `"dplyneage"`: OpenLineage job namespaces identify the producer, not
#' the data store. Passing an explicit `namespace` overrides all of this,
#' for datasets and job alike.
#'
#' @inheritParams lineage_json
#' @param path Optional file to write the JSON to. When supplied, the
#'   string is returned invisibly.
#' @param namespace Dataset and job namespace recorded in the event. The
#'   default `NULL` resolves each dataset's namespace from the connection
#'   captured at extraction time (see the Namespaces section); pass a
#'   string to override everything, matching your catalog's namespace
#'   when integrating.
#' @param job_name Name recorded for the job that produced this lineage.
#' @param run_id UUID identifying the run. Generated when `NULL` (the
#'   default); pass a fixed UUID for reproducible output.
#' @param event_time Event timestamp in ISO-8601 format. The current UTC
#'   time when `NULL` (the default); pass a fixed timestamp for
#'   reproducible output.
#' @param output_name Name recorded for the output dataset in place of
#'   the synthetic `"output"` node id of a single-query extraction — use
#'   it when the query's result lands in a known table. Errors on
#'   multi-model lineage, whose models already carry their real names.
#' @return A JSON string containing one OpenLineage `RunEvent` of type
#'   `COMPLETE`.
#' @family lineage exporters
#' @seealso [extract_lineage()] to compute lineage automatically
#' @export
#' @examples
#' lineage <- list(
#'   nodes = list(
#'     create_table_node("orders", c("order_id", "amount")),
#'     create_table_node("daily_totals", "total", table_type = "target")
#'   ),
#'   edges = list(
#'     create_column_edge("orders", "amount", "daily_totals", "total")
#'   )
#' )
#' lineage_openlineage(
#'   lineage,
#'   run_id = "00000000-0000-4000-8000-000000000000",
#'   event_time = "2026-01-01T00:00:00.000Z"
#' )
lineage_openlineage <- function(lineage, path = NULL,
                                namespace = NULL,
                                job_name = "extract_lineage",
                                run_id = NULL,
                                event_time = NULL,
                                pretty = TRUE,
                                output_name = NULL) {
  semantics <- ol_rename_output(lineage_semantics(lineage), output_name)
  event <- build_openlineage(
    semantics,
    namespace = namespace,
    job_name = job_name,
    run_id = run_id %||% ol_uuid(),
    event_time = event_time %||%
      format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
  )
  out <- jsonlite::toJSON(event, auto_unbox = TRUE, pretty = pretty)
  write_export(out, path)
}

#' @noRd
ol_producer <- "https://github.com/tgerke/dplyneage"

#' @noRd
build_openlineage <- function(semantics, namespace, job_name, run_id,
                              event_time) {
  types <- vapply(
    semantics$nodes,
    function(n) n$type %||% NA_character_,
    character(1)
  )
  is_output <- !is.na(types) & types %in% c("transform", "target")

  node_ns <- ol_node_namespaces(semantics, namespace)

  schema_facet <- function(columns) {
    list(
      `_producer` = ol_producer,
      `_schemaURL` = "https://openlineage.io/spec/facets/1-1-1/SchemaDatasetFacet.json",
      fields = lapply(as.character(columns), function(col) list(name = col))
    )
  }

  dataset_facets <- function(n) {
    facets <- list(schema = schema_facet(n$columns))
    data_source <- ol_datasource_facet(node_ns[[n$id]])
    if (!is.null(data_source)) {
      facets$dataSource <- data_source
    }
    facets
  }

  inputs <- lapply(semantics$nodes[!is_output], function(n) {
    list(
      namespace = node_ns[[n$id]],
      name = n$id,
      facets = dataset_facets(n)
    )
  })

  outputs <- lapply(semantics$nodes[is_output], function(n) {
    facets <- dataset_facets(n)
    fields <- ol_column_lineage_fields(semantics$edges, n$id, node_ns)
    if (length(fields) > 0) {
      facets$columnLineage <- list(
        `_producer` = ol_producer,
        `_schemaURL` = "https://openlineage.io/spec/facets/1-2-0/ColumnLineageDatasetFacet.json",
        fields = fields
      )
    }
    list(namespace = node_ns[[n$id]], name = n$id, facets = facets)
  })

  list(
    eventType = "COMPLETE",
    eventTime = event_time,
    run = list(runId = run_id),
    job = list(namespace = namespace %||% "dplyneage", name = job_name),
    inputs = inputs,
    outputs = outputs,
    producer = ol_producer,
    schemaURL = "https://openlineage.io/spec/2-0-2/OpenLineage.json#/definitions/RunEvent"
  )
}

#' Resolve each node's dataset namespace
#'
#' An explicit namespace applies to every dataset. Otherwise a model node
#' takes the namespace captured from its connection at extraction time,
#' and a base table takes the namespace of the first model that
#' referenced it (recovered from the first edge it feeds, which the
#' stitcher builds in model order); "dplyneage" fills the gaps —
#' hand-built graphs, simulated connections, unrecognized drivers.
#' @noRd
ol_node_namespaces <- function(semantics, namespace) {
  ids <- vapply(semantics$nodes, function(n) n$id, character(1))
  if (!is.null(namespace)) {
    return(stats::setNames(rep(namespace, length(ids)), ids))
  }
  models <- semantics$metadata$models
  model_ns <- function(m) models[[m]]$namespace %||% "dplyneage"
  ns <- stats::setNames(rep("dplyneage", length(ids)), ids)
  for (id in ids) {
    if (!is.null(models[[id]])) {
      ns[[id]] <- model_ns(id)
    } else {
      for (e in semantics$edges) {
        if (identical(e$source, id)) {
          ns[[id]] <- model_ns(e$target)
          break
        }
      }
    }
  }
  ns
}

#' The dataSource facet for a dataset, when its namespace is a real URI
#' @noRd
ol_datasource_facet <- function(ns) {
  if (!grepl(":", ns, fixed = TRUE)) {
    return(NULL)
  }
  list(
    `_producer` = ol_producer,
    `_schemaURL` = "https://openlineage.io/spec/facets/1-0-1/DatasourceDatasetFacet.json",
    name = ns,
    uri = ns
  )
}

#' Rename the synthetic output dataset of a single-query lineage
#' @noRd
ol_rename_output <- function(semantics, output_name) {
  if (is.null(output_name)) {
    return(semantics)
  }
  if (!is.character(output_name) || length(output_name) != 1 ||
    is.na(output_name) || !nzchar(output_name)) {
    stop("output_name must be a single non-empty string.", call. = FALSE)
  }
  types <- vapply(
    semantics$nodes,
    function(n) n$type %||% NA_character_,
    character(1)
  )
  out_idx <- which(!is.na(types) & types %in% c("transform", "target"))
  if (length(out_idx) != 1) {
    stop(
      "output_name renames the single output of a one-query lineage; ",
      "this lineage has ", length(out_idx), " output tables, which ",
      "already carry their model names.",
      call. = FALSE
    )
  }
  old <- semantics$nodes[[out_idx]]$id
  semantics$nodes[[out_idx]]$id <- output_name
  semantics$edges <- lapply(semantics$edges, function(e) {
    if (identical(e$source, old)) {
      e$source <- output_name
    }
    if (identical(e$target, old)) {
      e$target <- output_name
    }
    e
  })
  model_idx <- match(old, names(semantics$metadata$models))
  if (!is.na(model_idx)) {
    names(semantics$metadata$models)[model_idx] <- output_name
  }
  semantics
}

#' Build the columnLineage facet's fields object for one output dataset
#' @noRd
ol_column_lineage_fields <- function(edges, dataset, node_ns) {
  fields <- list()
  for (e in edges) {
    if (!identical(e$target, dataset)) next
    input <- list(
      namespace = node_ns[[e$source]] %||% "dplyneage",
      name = e$source,
      field = e$source_column
    )
    transformation <- ol_transformation(e$transformation, e$expression)
    if (!is.null(transformation)) {
      input$transformations <- list(transformation)
    }
    fields[[e$target_column]] <- list(
      inputFields = c(
        fields[[e$target_column]]$inputFields %||% list(),
        list(input)
      )
    )
  }
  fields
}

# dplyneage's edge classifications map onto OpenLineage's transformation
# type/subtype taxonomy; hand-built edges (no classification) map to NULL
#' @noRd
ol_transformation <- function(transformation, expression = NULL) {
  map <- list(
    identity = list(type = "DIRECT", subtype = "IDENTITY"),
    transformation = list(type = "DIRECT", subtype = "TRANSFORMATION"),
    aggregation = list(type = "DIRECT", subtype = "AGGREGATION"),
    filter = list(type = "INDIRECT", subtype = "FILTER"),
    join = list(type = "INDIRECT", subtype = "JOIN"),
    group_by = list(type = "INDIRECT", subtype = "GROUP_BY"),
    sort = list(type = "INDIRECT", subtype = "SORT")
  )
  if (is.null(transformation)) {
    return(NULL)
  }
  out <- map[[transformation]]
  if (is.null(out)) {
    return(NULL)
  }
  if (!is.null(expression)) {
    out$description <- expression
  }
  out
}

ol_uuid_state <- new.env(parent = emptyenv())

#' RFC 4122 version-4 UUID from R's RNG (no dependency needed)
#'
#' Draws under a private seed built from the clock, the process id, and a
#' per-session counter, then restores the caller's `.Random.seed`, so
#' exporting lineage neither advances nor creates the user's RNG stream.
#' @noRd
ol_uuid <- function() {
  old_seed <- get0(".Random.seed", envir = globalenv(), inherits = FALSE)
  on.exit(
    if (is.null(old_seed)) {
      if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
        rm(".Random.seed", envir = globalenv())
      }
    } else {
      assign(".Random.seed", old_seed, envir = globalenv())
    }
  )
  ol_uuid_state$n <- (ol_uuid_state$n %||% 0L) + 1L
  set.seed(as.integer(
    (as.numeric(Sys.time()) * 1000 + Sys.getpid() + ol_uuid_state$n * 7919) %%
      .Machine$integer.max
  ))

  hex <- function(n) {
    paste(sample(c(0:9, letters[1:6]), n, replace = TRUE), collapse = "")
  }
  paste0(
    hex(8), "-", hex(4), "-4", hex(3), "-",
    sample(c("8", "9", "a", "b"), 1), hex(3), "-", hex(12)
  )
}
