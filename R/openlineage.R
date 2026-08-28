#' Export lineage as OpenLineage events
#'
#' Serializes a lineage object to
#' [OpenLineage](https://openlineage.io/) JSON — the interchange format
#' that data catalogs and lineage backends (Marquez, DataHub,
#' OpenMetadata, ...) ingest. The default is one `RunEvent` with a
#' `ColumnLineage` facet on each output dataset; POST it to an
#' OpenLineage endpoint (see [lineage_emit()]) and dplyneage-extracted
#' lineage appears alongside lineage from dbt, Airflow, or Spark.
#'
#' @section Static lineage events:
#' dplyneage extracts lineage from code without running it, which is the
#' case OpenLineage defines run-less events for. `events = "job"` emits
#' one `JobEvent` per model — its job named after the model, its inputs
#' the datasets the model reads (upstream models included), its output
#' carrying the `columnLineage` facet — and `events = "dataset"` emits
#' one `DatasetEvent` per dataset, sources included, as a static schema
#' registration. Both carry no `run`, so no run has to be fabricated for
#' design-time lineage. Kinds combine: `events = c("job", "dataset")`
#' emits both sets in one document.
#'
#' When the selection yields a single event and `pretty = TRUE`, the
#' result is one indented JSON document. Anything else — several events,
#' or `pretty = FALSE` — is NDJSON, one compact event per line, the
#' format OpenLineage's `FileTransport` writes and replay tooling reads:
#' a committed events file can later be replayed into any backend.
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
#' @section Facets:
#' Beyond `schema`, `dataSource`, and `columnLineage` on datasets, the
#' event carries job facets: `jobType` (`BATCH`/`DPLYNEAGE`/`QUERY`) and,
#' for single-model lineage, `sql` with the analyzed query and its
#' dialect. Schema facet fields include a `type` when column types were
#' captured — from a live connection's tables, or a `schema` argument
#' with named entries like `list(orders = list(amount = "DOUBLE"))` —
#' and a `description` when column labels were: from `label` attributes
#' on a local frame (the haven/labelled convention), database column
#' comments, or [extract_lineage()]'s `labels` argument.
#' Indirect edges land in the `columnLineage` facet's dataset-level
#' `dataset` array rather than under individual output columns: filter,
#' join, group and sort columns shape the whole result, which is exactly
#' what that array expresses. Optional run facets (`nominalTime`,
#' `parent`) attach through the matching arguments.
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
#' @param events Which event kinds to emit: any combination of `"run"`
#'   (the default; one `RunEvent` for the whole extraction), `"job"`
#'   (run-less `JobEvent`s, one per model), and `"dataset"` (run-less
#'   `DatasetEvent`s, one per dataset). See the Static lineage events
#'   section.
#' @param event_type The run state a `"run"` event reports:
#'   `"COMPLETE"` (the default), `"START"`, `"RUNNING"`, `"ABORT"`,
#'   `"FAIL"`, or `"OTHER"`. Static events carry no run state.
#' @param output_name Name recorded for the output dataset in place of
#'   the synthetic `"output"` node id of a single-query extraction — use
#'   it when the query's result lands in a known table. Errors on
#'   multi-model lineage, whose models already carry their real names.
#' @param nominal_time One or two ISO-8601 timestamps — the scheduled
#'   `nominalStartTime` and optionally `nominalEndTime` — emitted as the
#'   `nominalTime` run facet. `NULL` (the default) omits the facet.
#' @param parent A `list(run_id = , job_name = )`, optionally with a
#'   `namespace`, identifying the orchestrating run this event belongs
#'   under (an Airflow task, a dbt run); emitted as the `parent` run
#'   facet. `NULL` (the default) omits the facet.
#' @return A JSON string: one indented event document, or NDJSON with
#'   one event per line (see the Static lineage events section for when
#'   each applies).
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
                                events = "run",
                                event_type = "COMPLETE",
                                output_name = NULL,
                                nominal_time = NULL,
                                parent = NULL) {
  events <- match.arg(events, c("run", "job", "dataset"), several.ok = TRUE)
  semantics <- ol_rename_output(lineage_semantics(lineage), output_name)
  ctx <- ol_context(
    semantics,
    namespace = namespace,
    job_name = job_name,
    run_id = run_id,
    event_time = event_time,
    event_type = event_type,
    nominal_time = nominal_time,
    parent = parent
  )
  out <- ol_serialize(ol_build_events(semantics, events, ctx), pretty)
  write_export(out, path)
}

#' Everything the event builders share, validated once
#' @noRd
ol_context <- function(semantics, namespace, job_name, run_id, event_time,
                       event_type, nominal_time, parent) {
  list(
    node_ns = ol_node_namespaces(semantics, namespace),
    job_ns = namespace %||% "dplyneage",
    job_name = job_name,
    run_id = run_id %||% ol_uuid(),
    event_time = event_time %||%
      format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"),
    event_type = match.arg(
      event_type,
      c("COMPLETE", "START", "RUNNING", "ABORT", "FAIL", "OTHER")
    ),
    run_facets = ol_run_facets(nominal_time, parent)
  )
}

#' The requested event kinds, in kind order, as a flat list of events
#' @noRd
ol_build_events <- function(semantics, kinds, ctx) {
  events <- list()
  for (kind in kinds) {
    events <- c(
      events,
      switch(
        kind,
        run = list(ol_run_event(semantics, ctx)),
        job = ol_job_events(semantics, ctx),
        dataset = ol_dataset_events(semantics, ctx)
      )
    )
  }
  events
}

#' One event per line when there are several: FileTransport's NDJSON
#' @noRd
ol_serialize <- function(events, pretty) {
  if (length(events) == 1 && pretty) {
    return(jsonlite::toJSON(events[[1]], auto_unbox = TRUE, pretty = TRUE))
  }
  lines <- vapply(
    events,
    function(e) as.character(jsonlite::toJSON(e, auto_unbox = TRUE)),
    character(1)
  )
  paste(lines, collapse = "\n")
}

#' @noRd
ol_producer <- "https://github.com/tgerke/dplyneage"

#' @noRd
ol_spec_url <- "https://openlineage.io/spec/2-0-2/OpenLineage.json"

#' A facet _schemaURL, fragment included, as the reference clients emit
#' @noRd
ol_facet_url <- function(version, name) {
  paste0(
    "https://openlineage.io/spec/facets/", version, "/", name,
    ".json#/$defs/", name
  )
}

#' Which nodes are outputs (transform or target)
#' @noRd
ol_is_output <- function(semantics) {
  types <- vapply(
    semantics$nodes,
    function(n) n$type %||% NA_character_,
    character(1)
  )
  !is.na(types) & types %in% c("transform", "target")
}

#' One OpenLineage dataset object; pass edges to attach column lineage
#' @noRd
ol_dataset <- function(n, ctx, edges = NULL) {
  facets <- list(schema = ol_schema_facet(n$columns, n$types, n$labels))
  data_source <- ol_datasource_facet(ctx$node_ns[[n$id]])
  if (!is.null(data_source)) {
    facets$dataSource <- data_source
  }
  if (!is.null(edges)) {
    column_lineage <- ol_column_lineage_facet(edges, n$id, ctx$node_ns)
    if (!is.null(column_lineage)) {
      facets$columnLineage <- column_lineage
    }
  }
  list(namespace = ctx$node_ns[[n$id]], name = n$id, facets = facets)
}

#' @noRd
ol_run_event <- function(semantics, ctx) {
  is_output <- ol_is_output(semantics)
  run <- list(runId = ctx$run_id)
  if (length(ctx$run_facets) > 0) {
    run$facets <- ctx$run_facets
  }
  list(
    eventType = ctx$event_type,
    eventTime = ctx$event_time,
    run = run,
    job = list(
      namespace = ctx$job_ns,
      name = ctx$job_name,
      facets = ol_job_facets(semantics$metadata$models)
    ),
    inputs = lapply(semantics$nodes[!is_output], ol_dataset, ctx = ctx),
    outputs = lapply(
      semantics$nodes[is_output],
      ol_dataset,
      ctx = ctx,
      edges = semantics$edges
    ),
    producer = ol_producer,
    schemaURL = paste0(ol_spec_url, "#/$defs/RunEvent")
  )
}

#' Run-less JobEvents: one design-time job per model
#'
#' A model's inputs are the distinct sources of the edges that target its
#' node — base tables and upstream models alike, so a downstream model's
#' JobEvent lists the model it reads as an input dataset.
#' @noRd
ol_job_events <- function(semantics, ctx) {
  models <- semantics$metadata$models
  if (length(models) == 0) {
    stop(
      "Static job events describe the models extract_lineage() records ",
      "in metadata; this lineage has none.",
      call. = FALSE
    )
  }
  nodes_by_id <- stats::setNames(
    semantics$nodes,
    vapply(semantics$nodes, function(n) n$id, character(1))
  )
  lapply(names(models), function(m) {
    incoming <- Filter(function(e) identical(e$target, m), semantics$edges)
    input_ids <- unique(vapply(incoming, function(e) e$source, character(1)))
    list(
      eventTime = ctx$event_time,
      job = list(
        namespace = ctx$job_ns,
        name = m,
        facets = ol_job_facets(models[m])
      ),
      # unname: a named list would serialize as an object, not an array
      inputs = unname(lapply(nodes_by_id[input_ids], ol_dataset, ctx = ctx)),
      outputs = list(
        ol_dataset(nodes_by_id[[m]], ctx, edges = semantics$edges)
      ),
      producer = ol_producer,
      schemaURL = paste0(ol_spec_url, "#/$defs/JobEvent")
    )
  })
}

#' Run-less DatasetEvents: one per node, sources included — a static
#' schema registration that needs no metadata
#' @noRd
ol_dataset_events <- function(semantics, ctx) {
  lapply(semantics$nodes, function(n) {
    list(
      eventTime = ctx$event_time,
      dataset = ol_dataset(n, ctx, edges = semantics$edges),
      producer = ol_producer,
      schemaURL = paste0(ol_spec_url, "#/$defs/DatasetEvent")
    )
  })
}

#' @noRd
ol_schema_facet <- function(columns, types = NULL, labels = NULL) {
  types <- as.list(types %||% list())
  labels <- as.list(labels %||% list())
  list(
    `_producer` = ol_producer,
    `_schemaURL` = ol_facet_url("1-2-0", "SchemaDatasetFacet"),
    fields = lapply(as.character(columns), function(col) {
      field <- list(name = col)
      if (!is.null(types[[col]])) {
        field$type <- types[[col]]
      }
      if (!is.null(labels[[col]])) {
        field$description <- labels[[col]]
      }
      field
    })
  )
}

#' The jobType job facet: what kind of thing produced this lineage
#' @noRd
ol_job_type_facet <- function() {
  list(
    `_producer` = ol_producer,
    `_schemaURL` = ol_facet_url("2-0-4", "JobTypeJobFacet"),
    processingType = "BATCH",
    integration = "DPLYNEAGE",
    jobType = "QUERY"
  )
}

#' The sql job facet, for lineage that carries exactly one model's query
#' @noRd
ol_sql_job_facet <- function(models) {
  if (length(models) != 1 || is.null(models[[1]]$sql)) {
    return(NULL)
  }
  facet <- list(
    `_producer` = ol_producer,
    `_schemaURL` = ol_facet_url("1-1-0", "SQLJobFacet"),
    query = models[[1]]$sql
  )
  if (!is.null(models[[1]]$dialect)) {
    facet$dialect <- models[[1]]$dialect
  }
  facet
}

#' @noRd
ol_job_facets <- function(models) {
  facets <- list(jobType = ol_job_type_facet())
  sql <- ol_sql_job_facet(models)
  if (!is.null(sql)) {
    facets$sql <- sql
  }
  facets
}

#' Run facets from the nominal_time and parent arguments
#' @noRd
ol_run_facets <- function(nominal_time, parent) {
  facets <- list()
  if (!is.null(nominal_time)) {
    if (!is.character(nominal_time) || !(length(nominal_time) %in% 1:2) ||
      anyNA(nominal_time)) {
      stop(
        "nominal_time must be one or two ISO-8601 timestamps: ",
        "nominalStartTime, and optionally nominalEndTime.",
        call. = FALSE
      )
    }
    facet <- list(
      `_producer` = ol_producer,
      `_schemaURL` = ol_facet_url("1-0-1", "NominalTimeRunFacet"),
      nominalStartTime = nominal_time[[1]]
    )
    if (length(nominal_time) == 2) {
      facet$nominalEndTime <- nominal_time[[2]]
    }
    facets$nominalTime <- facet
  }
  if (!is.null(parent)) {
    if (!is.list(parent) || is.null(parent$run_id) ||
      is.null(parent$job_name)) {
      stop(
        "parent must be a list with run_id and job_name ",
        "(and optionally namespace).",
        call. = FALSE
      )
    }
    facets$parent <- list(
      `_producer` = ol_producer,
      `_schemaURL` = ol_facet_url("1-2-0", "ParentRunFacet"),
      run = list(runId = parent$run_id),
      job = list(
        namespace = parent$namespace %||% "dplyneage",
        name = parent$job_name
      )
    )
  }
  facets
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

# The classifications that shape the whole dataset rather than one column
ol_indirect_kinds <- c("filter", "join", "group_by", "sort")

#' Build the columnLineage facet for one output dataset
#'
#' Direct edges map output columns to their input fields. Indirect edges
#' (filter/join/group/sort columns) go to the facet's dataset-level
#' `dataset` array instead — they shape the whole result, and the graph
#' fans each one out to every output column, which would bloat and
#' distort per-column lineage. One array entry per source column, with
#' the distinct kinds as its transformations. Returns NULL when there is
#' nothing to report (an empty facet is spec-invalid).
#' @noRd
ol_column_lineage_facet <- function(edges, dataset, node_ns) {
  fields <- list()
  dataset_deps <- list()
  dep_order <- character()
  for (e in edges) {
    if (!identical(e$target, dataset)) next
    if (!is.null(e$transformation) && e$transformation %in% ol_indirect_kinds) {
      key <- paste0(e$source, "\r", e$source_column)
      if (is.null(dataset_deps[[key]])) {
        dataset_deps[[key]] <- list(
          namespace = node_ns[[e$source]] %||% "dplyneage",
          name = e$source,
          field = e$source_column,
          kinds = character(0)
        )
        dep_order <- c(dep_order, key)
      }
      dataset_deps[[key]]$kinds <- union(
        dataset_deps[[key]]$kinds,
        as.character(e$transformations %||% e$transformation)
      )
      next
    }
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

  dataset_array <- lapply(dep_order, function(key) {
    dep <- dataset_deps[[key]]
    list(
      namespace = dep$namespace,
      name = dep$name,
      field = dep$field,
      transformations = lapply(dep$kinds, ol_transformation)
    )
  })

  if (length(fields) == 0 && length(dataset_array) == 0) {
    return(NULL)
  }
  facet <- list(
    `_producer` = ol_producer,
    `_schemaURL` = ol_facet_url("1-2-0", "ColumnLineageDatasetFacet"),
    # The spec requires `fields`; an empty named list serializes as {}
    fields = if (length(fields) == 0) {
      structure(list(), names = character(0))
    } else {
      fields
    }
  )
  if (length(dataset_array) > 0) {
    facet$dataset <- dataset_array
  }
  facet
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
