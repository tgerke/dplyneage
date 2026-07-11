#' Extract column lineage from a dplyr pipeline or SQL query
#'
#' `extract_lineage()` traces every output column of a query back to the
#' source table columns it was computed from. Pipe a dbplyr lazy table
#' straight into it, or pass a SQL string. Aliases, CTEs, subqueries, set
#' operations like `UNION`, and multi-source expressions such as
#' `COALESCE(a.x, b.x)` all resolve to their true source columns.
#'
#' Two engines are available. dbplyr lazy tables are analyzed by a pure-R
#' fast path that walks the pipeline's lazy query tree directly — no Python
#' required. SQL strings are analyzed by
#' [sqlglot](https://github.com/tobymao/sqlglot)'s lineage engine via
#' reticulate (a Suggests dependency: install reticulate to enable this
#' engine; sqlglot itself is provisioned automatically). If a pipeline uses
#' a construct the R engine cannot trace (e.g. raw SQL injected with
#' `dbplyr::sql()`), it falls back to sqlglot automatically.
#'
#' Both engines trace select-list lineage by default: columns used only in
#' `filter()`, join conditions, or `arrange()` do not create lineage
#' edges. Set `include_indirect = TRUE` to add them as dashed edges — a
#' column that only filters the result still breaks the pipeline if it is
#' dropped, so impact analysis usually wants them. Indirect edges connect
#' each filter/join/group/sort column to every output column, since these
#' conditions shape the whole result, and are classified by how the column
#' is used (`"filter"`, `"join"`, `"group_by"`, `"sort"`).
#'
#' A named list stitches a multi-model pipeline into one graph. Each
#' element (lazy table or SQL string) is analyzed on its own, and any
#' source table whose name matches another element's name connects to that
#' model's node — so a bronze/silver/gold flow where each layer is
#' materialized under its model's name renders as a single multi-hop DAG,
#' with intermediate models drawn as orange transform nodes and terminal
#' models as green targets.
#'
#' @param sql A dbplyr lazy table (`tbl_lazy`), a single SQL query string,
#'   or a named list of these (one element per pipeline model; see
#'   Details). Lazy tables are analyzed directly from their lazy query
#'   tree (the SQL recorded in `metadata` still comes from
#'   [dbplyr::sql_render()]); when one is handled by the sqlglot engine
#'   instead, its database connection is used to harvest table schemas
#'   automatically. Plain data frames are not accepted — dplyr executes
#'   each verb on them immediately, leaving no query tree to read. Wrap
#'   the data with [dbplyr::memdb_frame()] (or copy an existing frame
#'   with `copy_to(dbplyr::memdb(), df, name = "df")`) and the same
#'   pipeline becomes traceable; see `vignette("getting-started")`.
#' @param dialect SQL dialect the query is written in, e.g. `"duckdb"`
#'   (the default), `"postgres"`, `"mysql"`, `"snowflake"`, `"bigquery"`.
#'   Any dialect sqlglot understands works here.
#' @param schema Optional table schema used by the sqlglot engine to
#'   attribute unqualified columns to the right table and to expand
#'   `SELECT *`: a named list mapping table names to character vectors of
#'   column names, e.g. `list(orders = c("order_id", "amount"))`. Only
#'   relevant for SQL strings — the R engine reads exact provenance from
#'   the lazy query tree, and a lazy table that falls back to sqlglot
#'   harvests its schema from the database connection automatically.
#' @param show_sql If `TRUE`, print the SQL being analyzed. Useful for
#'   seeing what dbplyr generated from your pipeline. Default: `FALSE`.
#' @param engine Which lineage engine to use. `"auto"` (the default) uses
#'   the pure-R engine for lazy tables when dbplyr (>= 2.5.0) is installed,
#'   falling back to sqlglot for SQL strings or unsupported constructs.
#'   `"r"` forces the pure-R engine and errors on anything it cannot trace.
#'   `"sqlglot"` always renders to SQL and analyzes with sqlglot.
#' @param include_indirect If `TRUE`, columns used in `filter()`/`WHERE`,
#'   join conditions, `group_by()`, and `arrange()`/`ORDER BY` also appear
#'   in the diagram, connected by dashed edges (see Details). Default:
#'   `FALSE`, matching most lineage tools.
#' @return A list with `nodes` and `edges` ready to pass to
#'   [lineage_flow()], plus `metadata` recording the analyzed SQL, the
#'   dialect, the engine used, and node/edge counts.
#' @seealso [lineage_flow()] to render the result;
#'   `vignette("getting-started")` for a tour from simple pipelines to
#'   CTEs and multi-source columns.
#' @export
#' @examplesIf dplyneage::has_sqlglot()
#' # Raw SQL: qualified columns resolve on their own
#' extract_lineage("SELECT c.id, c.name FROM customers c") |>
#'   lineage_flow()
#'
#' # Supply a schema so unqualified columns attribute to the right table
#' # and SELECT * expands
#' extract_lineage(
#'   "SELECT c.name, order_date FROM customers c
#'    JOIN orders o ON c.id = o.customer_id",
#'   schema = list(
#'     customers = c("id", "name"),
#'     orders = c("customer_id", "order_date")
#'   )
#' )
#' @examplesIf requireNamespace("dplyr", quietly = TRUE) && requireNamespace("dbplyr", quietly = TRUE) && requireNamespace("duckdb", quietly = TRUE)
#' # dbplyr pipelines: pipe straight in; the pure-R engine reads exact
#' # provenance from the pipeline itself, no Python needed
#' library(dplyr)
#'
#' con <- DBI::dbConnect(duckdb::duckdb())
#' DBI::dbWriteTable(con, "customers", data.frame(id = 1, name = "a"))
#' DBI::dbWriteTable(con, "orders", data.frame(customer_id = 1, amount = 10))
#'
#' tbl(con, "customers") |>
#'   left_join(tbl(con, "orders"), by = c("id" = "customer_id")) |>
#'   group_by(id, name) |>
#'   summarise(total_spent = sum(amount, na.rm = TRUE), .groups = "drop") |>
#'   extract_lineage() |>
#'   lineage_flow()
#'
#' # Multi-model pipelines: name each step and pass a named list; source
#' # tables matching a model name stitch the layers into one DAG
#' silver <- tbl(con, "orders") |>
#'   group_by(customer_id) |>
#'   summarise(total_spent = sum(amount, na.rm = TRUE), .groups = "drop")
#' invisible(compute(silver, name = "silver", temporary = TRUE))
#' gold <- tbl(con, "silver") |>
#'   mutate(big_spender = total_spent > 100)
#'
#' extract_lineage(list(silver = silver, gold = gold)) |>
#'   lineage_flow()
#'
#' DBI::dbDisconnect(con)
extract_lineage <- function(sql, dialect = "duckdb", schema = NULL, show_sql = FALSE,
                            engine = c("auto", "sqlglot", "r"),
                            include_indirect = FALSE) {
  engine <- match.arg(engine)

  # Catch plain data frames up front: they'd otherwise fall through to the
  # sqlglot branch and fail with errors about Python or SQL strings that
  # never mention the actual fix
  if (is.data.frame(sql)) {
    stop(
      "extract_lineage() reads lineage from a lazy query tree, which a ",
      "plain data frame doesn't have. Wrap it first: ",
      "dbplyr::memdb_frame() for new data, or ",
      "copy_to(dbplyr::memdb(), df, name = \"df\") for an existing frame. ",
      "See vignette(\"getting-started\").",
      call. = FALSE
    )
  }

  # A bare named list is a multi-model pipeline: each element is analyzed
  # on its own, then stitched into one graph by matching source tables to
  # model names
  if (is.list(sql) && !is.object(sql)) {
    return(extract_lineage_pipeline(
      sql, dialect, schema, show_sql, engine, include_indirect
    ))
  }

  convert_lineage_to_graph(
    extract_lineage_data(sql, dialect, schema, show_sql, engine, include_indirect)
  )
}

#' Run one query through the engine dispatch, returning lineage_data
#'
#' The single-query core of [extract_lineage()]: engine selection, R-engine
#' fallback, schema harvesting, and sqlglot extraction, without the final
#' conversion to a graph — so pipelines can stitch several results first.
#' @noRd
extract_lineage_data <- function(sql, dialect, schema, show_sql, engine,
                                 include_indirect = FALSE) {
  is_lazy <- inherits(sql, "tbl_lazy")

  if (engine == "r") {
    if (!is_lazy) {
      stop(
        "engine = \"r\" only works with dbplyr lazy tables; ",
        "SQL strings need the sqlglot engine.",
        call. = FALSE
      )
    }
    if (!r_engine_available()) {
      stop(
        "The pure-R lineage engine requires dbplyr (>= 2.5.0).",
        call. = FALSE
      )
    }
    lineage_data <- extract_lineage_from_tbl(sql, dialect, include_indirect)
    if (show_sql) {
      show_analyzed_sql(lineage_data$sql)
    }
    return(lineage_data)
  }

  # Fast path: walk the lazy query tree in R, no Python needed. Falls
  # through to sqlglot if the query uses a construct the walker can't trace.
  if (engine == "auto" && is_lazy && r_engine_available()) {
    lineage_data <- tryCatch(
      extract_lineage_from_tbl(sql, dialect, include_indirect),
      dplyneage_unsupported_lineage = function(cnd) {
        if (!has_sqlglot()) {
          stop(
            conditionMessage(cnd),
            " The sqlglot engine can trace this query, but Python sqlglot ",
            "is not available.",
            call. = FALSE
          )
        }
        message("Falling back to the sqlglot engine: ", conditionMessage(cnd))
        NULL
      }
    )
    if (!is.null(lineage_data)) {
      if (show_sql) {
        show_analyzed_sql(lineage_data$sql)
      }
      return(lineage_data)
    }
  }

  # sqlglot engine
  if (!has_sqlglot()) {
    if (!reticulate_available()) {
      stop(
        "Analyzing this input needs the sqlglot engine, which requires the ",
        "'reticulate' package. Install it with ",
        "install.packages(\"reticulate\"); sqlglot itself is then ",
        "provisioned automatically.",
        call. = FALSE
      )
    }
    stop(
      "Python package 'sqlglot' is required for lineage extraction.\n",
      "dplyneage requests it automatically via reticulate::py_require(); ",
      "if you manage your own Python environment, install sqlglot into it ",
      "(e.g. pip install sqlglot).",
      call. = FALSE
    )
  }

  # Convert dbplyr query to SQL if needed, keeping the connection so we can
  # harvest the table schemas for accurate column attribution
  con <- NULL
  if (is_lazy) {
    con <- dbplyr::remote_con(sql)
    sql <- get_sql_from_dplyr(sql)
  }

  # Ensure we have a single character string
  if (!is.character(sql) || length(sql) != 1) {
    stop(
      "sql must be a character string, a dbplyr lazy table, or a named ",
      "list of them",
      call. = FALSE
    )
  }

  if (show_sql) {
    show_analyzed_sql(sql)
  }

  if (is.null(schema) && !is.null(con)) {
    schema <- harvest_schema(con, sql, dialect)
  }

  # Extract lineage using sqlglot
  extract_lineage_from_sql(sql, dialect, schema, include_indirect)
}

#' Print the SQL being analyzed (the `show_sql = TRUE` output)
#' @noRd
show_analyzed_sql <- function(sql) {
  cat("Analyzing SQL:\n")
  cat(sql, "\n\n")
}

#' Get SQL String from dplyr Query
#'
#' Converts a dbplyr lazy table to SQL string using sql_render
#'
#' @param query A dbplyr lazy table (tbl_lazy)
#' @return Character string containing SQL query
#' @keywords internal
get_sql_from_dplyr <- function(query) {
  if (!inherits(query, "tbl_lazy")) {
    stop("query must be a dbplyr lazy table (tbl_lazy)", call. = FALSE)
  }

  if (!requireNamespace("dbplyr", quietly = TRUE)) {
    stop(
      "Package 'dbplyr' is required to extract lineage from a lazy table.",
      call. = FALSE
    )
  }

  # Get SQL from dbplyr
  sql_obj <- dbplyr::sql_render(query)

  # Convert to character
  as.character(sql_obj)
}

#' Harvest Table Schemas from a Database Connection
#'
#' Lists the columns of each base table referenced by the query so sqlglot
#' can resolve unqualified columns and expand `*`. Returns NULL if the
#' schema cannot be determined (lineage extraction still works, with
#' reduced attribution accuracy).
#'
#' @param con A DBI connection
#' @param sql SQL query string
#' @param dialect SQL dialect
#' @return Named list mapping table names to character vectors of columns,
#'   or NULL
#' @keywords internal
harvest_schema <- function(con, sql, dialect = "duckdb") {
  if (is.null(con) || !requireNamespace("DBI", quietly = TRUE)) {
    return(NULL)
  }

  tables <- tryCatch(
    lineage_module()$list_tables(sql, dialect = dialect),
    error = function(e) NULL
  )
  if (length(tables) == 0) {
    return(NULL)
  }

  schema <- list()
  for (tbl in tables) {
    # Qualified names (schema.table) need a DBI::Id lookup, not a bare string
    parts <- strsplit(tbl$name, ".", fixed = TRUE)[[1]]
    ref <- if (length(parts) > 1) DBI::Id(parts) else tbl$name
    fields <- tryCatch(
      DBI::dbListFields(con, ref),
      error = function(e) NULL
    )
    if (!is.null(fields)) {
      schema[[tbl$name]] <- fields
    }
  }

  if (length(schema) == 0) NULL else schema
}

#' Extract Lineage from SQL using sqlglot
#'
#' Internal function that calls the bundled Python module (built on
#' sqlglot.lineage) to parse SQL and trace each output column to its
#' source columns.
#'
#' @param sql SQL query string
#' @param dialect SQL dialect
#' @param schema Optional named list mapping table names to column vectors
#' @param include_indirect Also collect filter/join/group/sort columns?
#' @return List containing tables, columns, sql, and dialect
#' @keywords internal
extract_lineage_from_sql <- function(sql, dialect = "duckdb", schema = NULL,
                                     include_indirect = FALSE) {
  result <- tryCatch(
    lineage_module()$extract_lineage(
      sql,
      dialect = dialect, schema = schema, include_indirect = include_indirect
    ),
    error = function(e) {
      stop(
        "Failed to extract lineage from SQL.\n",
        "SQL: ", sql, "\n",
        "Error: ", conditionMessage(e),
        call. = FALSE
      )
    }
  )

  # Surface anything the Python layer could not trace as R warnings
  for (w in result$warnings) {
    warning(w, call. = FALSE)
  }

  out <- list(
    tables = result$tables,
    columns = result$columns,
    sql = sql,
    dialect = dialect
  )
  if (include_indirect) {
    out$indirect <- result$indirect
  }
  out
}

#' Convert Lineage Data to Graph Structure
#'
#' Converts lineage information to nodes and edges for visualization
#'
#' @param lineage_data Processed lineage data
#' @return List with nodes and edges
#' @keywords internal
convert_lineage_to_graph <- function(lineage_data) {
  columns <- lineage_data$columns
  indirect <- lineage_data$indirect %||% list()

  # Group source columns by table; indirect sources (filter/join/group/
  # sort columns) join their table's node like any other column
  tables_with_columns <- list()
  add_table_column <- function(source) {
    table_name <- source_table_name(source)
    if (!table_name %in% names(tables_with_columns)) {
      tables_with_columns[[table_name]] <<- list()
    }
    if (!source$column_name %in% tables_with_columns[[table_name]]) {
      tables_with_columns[[table_name]] <<- c(
        tables_with_columns[[table_name]],
        source$column_name
      )
    }
  }
  for (col in columns) {
    for (source in col$sources) {
      add_table_column(source)
    }
  }
  for (source in indirect) {
    add_table_column(source)
  }

  source_tables <- names(tables_with_columns)

  # The synthetic output node must not collide with a real table name
  output_table <- "output"
  while (output_table %in% source_tables) {
    output_table <- paste0(output_table, "_")
  }

  output_columns <- unique(vapply(
    columns,
    function(col) col$output_name,
    character(1)
  ))

  # Node specs: sources in layer 0, output in layer 1
  specs <- lapply(source_tables, function(table_name) {
    list(
      id = table_name,
      columns = unlist(tables_with_columns[[table_name]]),
      type = "source",
      layer = 0L
    )
  })
  if (length(output_columns) > 0) {
    specs[[length(specs) + 1]] <- list(
      id = output_table,
      columns = output_columns,
      type = "target",
      layer = 1L
    )
  }
  nodes <- build_layout_nodes(specs)

  # Create edges based on column lineage
  edges <- list()
  edge_keys <- character()
  for (col in columns) {
    for (source in col$sources) {
      edges[[length(edges) + 1]] <- lineage_edge_for(col, source, output_table)
      edge_keys <- c(edge_keys, paste0(
        source_table_name(source), ".", source$column_name,
        "->", col$output_name
      ))
    }
  }

  # Indirect columns shape the whole result, so each connects to every
  # output column — dashed, and skipped where a direct edge already exists
  for (source in indirect) {
    for (output_column in output_columns) {
      key <- paste0(
        source_table_name(source), ".", source$column_name,
        "->", output_column
      )
      if (key %in% edge_keys) next
      edge_keys <- c(edge_keys, key)
      edges[[length(edges) + 1]] <-
        indirect_edge_for(source, output_table, output_column)
    }
  }

  structure(
    list(
      nodes = nodes,
      edges = edges,
      metadata = list(
        sql = lineage_data$sql,
        dialect = lineage_data$dialect,
        engine = if (is.null(lineage_data$engine)) "sqlglot" else lineage_data$engine,
        node_count = length(nodes),
        edge_count = length(edges)
      )
    ),
    class = "dplyneage_lineage"
  )
}

# Edge labels stay readable; the full expression is kept in edge$data
#' @noRd
truncate_label <- function(x, max = 40) {
  if (nchar(x) > max) paste0(substr(x, 1, max - 1), "\u2026") else x
}

# Sources with no usable table name (NULL, NA, empty) group under "unknown"
#' @noRd
source_table_name <- function(source) {
  table <- source$table
  if (is.null(table) || length(table) != 1 || is.na(table) || !nzchar(table)) {
    return("unknown")
  }
  table
}
