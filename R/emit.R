#' Send OpenLineage events to a backend over HTTP
#'
#' Builds the same events as [lineage_openlineage()] and POSTs each one
#' to an OpenLineage endpoint, so dplyneage-extracted lineage lands in a
#' running catalog — Marquez, DataHub, or anything else that speaks the
#' protocol — next to lineage from dbt, Airflow, or Spark. One request
#' per event, JSON body, matching how the reference OpenLineage clients
#' transport events.
#'
#' The default endpoint path `api/v1/lineage` is where Marquez listens;
#' for other backends set `endpoint` (DataHub, for example, exposes the
#' OpenLineage endpoint under its own prefix). Marquez accepts run
#' events and the static `events = "job"` / `events = "dataset"` kinds
#' alike.
#'
#' @inheritParams lineage_openlineage
#' @param url Base URL of the OpenLineage backend, e.g.
#'   `"http://localhost:5000"` for a local Marquez. Defaults to the
#'   `OPENLINEAGE_URL` environment variable, the same one the reference
#'   clients read.
#' @param api_key Bearer token added as an `Authorization` header.
#'   Defaults to the `OPENLINEAGE_API_KEY` environment variable; unset
#'   means no auth header.
#' @param headers A named character vector or list of extra HTTP
#'   headers.
#' @param endpoint Path of the lineage endpoint under `url`.
#' @return Invisibly, a data frame with one row per event sent: `event`
#'   (index) and `status` (HTTP status code).
#' @section Errors:
#' A failed request — connection refused, or an HTTP error status —
#' stops with a condition of class `dplyneage_emit_failure` carrying
#' `event` (the failing index), `status` (the HTTP status, `NA` when the
#' request never got a response), and `results` (the rows for events
#' already sent). Events after the failing one are not sent.
#' @family lineage exporters
#' @seealso [lineage_openlineage()] for the event documents themselves
#' @export
#' @examples
#' \dontrun{
#' lineage <- extract_lineage(my_query)
#'
#' # A local Marquez quickstart listens on port 5000
#' lineage_emit(lineage, url = "http://localhost:5000")
#'
#' # Design-time lineage, no fabricated run, nested under a known job
#' lineage_emit(lineage, url = "http://localhost:5000", events = "job")
#' }
lineage_emit <- function(lineage, url = NULL,
                         events = "run",
                         namespace = NULL,
                         job_name = "extract_lineage",
                         run_id = NULL,
                         event_time = NULL,
                         event_type = "COMPLETE",
                         output_name = NULL,
                         nominal_time = NULL,
                         parent = NULL,
                         api_key = NULL,
                         headers = NULL,
                         endpoint = "api/v1/lineage") {
  if (!requireNamespace("httr2", quietly = TRUE)) {
    stop(
      "lineage_emit() sends events over HTTP, which requires the ",
      "'httr2' package. Install it with install.packages(\"httr2\").",
      call. = FALSE
    )
  }
  url <- url %||% Sys.getenv("OPENLINEAGE_URL")
  if (!is.character(url) || length(url) != 1 || !nzchar(url)) {
    stop(
      "No OpenLineage backend to send to: pass `url`, or set the ",
      "OPENLINEAGE_URL environment variable.",
      call. = FALSE
    )
  }
  api_key <- api_key %||% Sys.getenv("OPENLINEAGE_API_KEY")
  if (!nzchar(api_key %||% "")) {
    api_key <- NULL
  }

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
  event_list <- ol_build_events(semantics, events, ctx)

  results <- data.frame(event = integer(0), status = integer(0))
  for (i in seq_along(event_list)) {
    req <- httr2::request(url)
    req <- httr2::req_url_path_append(req, endpoint)
    req <- httr2::req_user_agent(req, ol_producer)
    # Serialize with the same settings as lineage_openlineage() rather
    # than letting httr2 re-encode the event
    req <- httr2::req_body_raw(
      req,
      charToRaw(as.character(
        jsonlite::toJSON(event_list[[i]], auto_unbox = TRUE)
      )),
      type = "application/json"
    )
    if (!is.null(api_key)) {
      req <- httr2::req_auth_bearer_token(req, api_key)
    }
    if (length(headers) > 0) {
      req <- do.call(httr2::req_headers, c(list(req), as.list(headers)))
    }

    resp <- tryCatch(httr2::req_perform(req), error = function(e) e)
    status <- if (inherits(resp, "error")) {
      cnd_resp <- resp$resp
      if (is.null(cnd_resp)) NA_integer_ else httr2::resp_status(cnd_resp)
    } else {
      httr2::resp_status(resp)
    }
    if (inherits(resp, "error")) {
      stop(errorCondition(
        paste0(
          "Emitting OpenLineage event ", i, " of ", length(event_list),
          " to ", url, " failed: ", conditionMessage(resp)
        ),
        event = i,
        status = status,
        results = results,
        class = c("dplyneage_emit_failure", "error", "condition")
      ))
    }
    results[nrow(results) + 1L, ] <- list(i, status)
  }
  invisible(results)
}
