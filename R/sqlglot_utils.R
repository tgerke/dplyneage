#' Extract column lineage from a dplyr pipeline or SQL query
#'
#' `extract_lineage()` traces every output column of a query back to the
#' source table columns it was computed from, using
#' [sqlglot](https://github.com/tobymao/sqlglot)'s lineage engine. Pipe a
#' dbplyr lazy table straight into it, or pass a SQL string. Aliases, CTEs,
#' subqueries, set operations like `UNION`, and multi-source expressions
#' such as `COALESCE(a.x, b.x)` all resolve to their true source columns.
#'
#' @param sql A dbplyr lazy table (`tbl_lazy`) or a single SQL query string.
#'   Lazy tables are rendered to SQL with [dbplyr::sql_render()], and their
#'   database connection is used to harvest table schemas automatically.
#' @param dialect SQL dialect the query is written in, e.g. `"duckdb"`
#'   (the default), `"postgres"`, `"mysql"`, `"snowflake"`, `"bigquery"`.
#'   Any dialect sqlglot understands works here.
#' @param schema Optional table schema used to attribute unqualified columns
#'   to the right table and to expand `SELECT *`: a named list mapping table
#'   names to character vectors of column names, e.g.
#'   `list(orders = c("order_id", "amount"))`. When `sql` is a dbplyr lazy
#'   table this is harvested from the database connection, so you rarely
#'   need to supply it yourself.
#' @param show_sql If `TRUE`, print the SQL being analyzed. Useful for
#'   seeing what dbplyr generated from your pipeline. Default: `FALSE`.
#' @return A list with `nodes` and `edges` ready to pass to
#'   [lineage_flow()], plus `metadata` recording the analyzed SQL, the
#'   dialect, and node/edge counts.
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
#' @examplesIf dplyneage::has_sqlglot() && requireNamespace("dplyr", quietly = TRUE) && requireNamespace("dbplyr", quietly = TRUE) && requireNamespace("duckdb", quietly = TRUE)
#' # dbplyr pipelines: pipe straight in; the schema is read from the
#' # connection so attribution is exact
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
#' DBI::dbDisconnect(con)
extract_lineage <- function(sql, dialect = "duckdb", schema = NULL, show_sql = FALSE) {
  # Ensure sqlglot is available
  if (!has_sqlglot()) {
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
  if (inherits(sql, "tbl_lazy")) {
    con <- dbplyr::remote_con(sql)
    sql <- get_sql_from_dplyr(sql)
  }

  # Ensure we have a single character string
  if (!is.character(sql) || length(sql) != 1) {
    stop("sql must be a character string or a dbplyr lazy table", call. = FALSE)
  }

  # Optionally show the SQL being analyzed
  if (show_sql) {
    cat("Analyzing SQL:\n")
    cat(sql, "\n\n")
  }

  if (is.null(schema) && !is.null(con)) {
    schema <- harvest_schema(con, sql, dialect)
  }

  # Extract lineage using sqlglot
  lineage_data <- extract_lineage_from_sql(sql, dialect, schema)

  # Convert to nodes and edges format
  convert_lineage_to_graph(lineage_data)
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
    .dplyneage$lineage$list_tables(sql, dialect = dialect),
    error = function(e) NULL
  )
  if (length(tables) == 0) {
    return(NULL)
  }

  schema <- list()
  for (tbl in tables) {
    fields <- tryCatch(
      DBI::dbListFields(con, tbl$name),
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
#' @return List containing tables, columns, sql, and dialect
#' @keywords internal
extract_lineage_from_sql <- function(sql, dialect = "duckdb", schema = NULL) {
  result <- tryCatch(
    .dplyneage$lineage$extract_lineage(sql, dialect = dialect, schema = schema),
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

  list(
    tables = result$tables,
    columns = result$columns,
    sql = sql,
    dialect = dialect
  )
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

  # Group columns by table
  tables_with_columns <- list()
  output_table <- "output"

  for (col in columns) {
    # Add output column to output table
    if (!output_table %in% names(tables_with_columns)) {
      tables_with_columns[[output_table]] <- list()
    }
    if (!col$output_name %in% tables_with_columns[[output_table]]) {
      tables_with_columns[[output_table]] <- c(
        tables_with_columns[[output_table]],
        col$output_name
      )
    }

    # Add source columns to source tables
    for (source in col$sources) {
      table_name <- source$table
      if (is.null(table_name) || is.na(table_name)) {
        table_name <- "unknown"
      }

      if (!table_name %in% names(tables_with_columns)) {
        tables_with_columns[[table_name]] <- list()
      }
      if (!source$column_name %in% tables_with_columns[[table_name]]) {
        tables_with_columns[[table_name]] <- c(
          tables_with_columns[[table_name]],
          source$column_name
        )
      }
    }
  }

  # Create nodes
  nodes <- list()
  x_pos <- 0
  y_pos <- 0
  y_spacing <- 200
  x_spacing <- 400

  source_tables <- setdiff(names(tables_with_columns), output_table)

  for (i in seq_along(source_tables)) {
    table_name <- source_tables[i]
    cols <- unlist(tables_with_columns[[table_name]])

    if (length(cols) > 0) {
      nodes[[length(nodes) + 1]] <- create_table_node(
        table_name = table_name,
        columns = cols,
        x = x_pos,
        y = y_pos + (i - 1) * y_spacing,
        table_type = "source"
      )
    }
  }

  # Add output table
  if (output_table %in% names(tables_with_columns)) {
    cols <- unlist(tables_with_columns[[output_table]])
    if (length(cols) > 0) {
      nodes[[length(nodes) + 1]] <- create_table_node(
        table_name = output_table,
        columns = cols,
        x = x_pos + x_spacing,
        y = y_pos + max(length(source_tables) - 1, 0) * y_spacing / 2,
        table_type = "target"
      )
    }
  }

  # Create edges based on column lineage
  edges <- list()

  for (col in columns) {
    target_col <- col$output_name

    for (source in col$sources) {
      source_table <- if (!is.null(source$table)) source$table else "unknown"
      source_col <- source$column_name

      # Only create edge if source table exists in our nodes
      if (source_table %in% names(tables_with_columns)) {
        edges[[length(edges) + 1]] <- create_column_edge(
          from_table = source_table,
          from_column = source_col,
          to_table = output_table,
          to_column = target_col
        )
      }
    }
  }

  list(
    nodes = nodes,
    edges = edges,
    metadata = list(
      sql = lineage_data$sql,
      dialect = lineage_data$dialect,
      table_count = length(nodes),
      edge_count = length(edges)
    )
  )
}
