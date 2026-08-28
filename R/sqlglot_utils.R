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
#' edges. A window function's partition and ordering columns do — they sit
#' inside the expression's `OVER` clause, so `row_number()` under
#' `group_by(g)` and `window_order(d)` draws direct edges from both `g`
#' and `d`. Set `include_indirect = TRUE` to add the rest as dashed
#' edges — a column that only filters the result still breaks the
#' pipeline if it is dropped, so impact analysis usually wants them.
#' Indirect edges connect each filter/join/group/sort column (window
#' `ORDER BY` columns included) to every output column, since these
#' conditions shape the whole result, and are classified by how the
#' column is used (`"filter"`, `"join"`, `"group_by"`, `"sort"`).
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
#'   the frame first: `dbplyr::tbl_lazy(df, name = "df")` builds a lazy
#'   table with no database at all, which is enough for lineage;
#'   [dbplyr::memdb_frame()] (or `copy_to(dbplyr::memdb(), df, name =
#'   "df")`) additionally makes the pipeline collectable. See
#'   `vignette("getting-started")`.
#' @param dialect SQL dialect the query is written in, e.g. `"duckdb"`,
#'   `"postgres"`, `"mysql"`, `"snowflake"`, `"bigquery"`. Any dialect
#'   sqlglot understands works here. The default `NULL` infers the
#'   dialect from a lazy table's database connection (falling back to
#'   `"duckdb"` for connections it does not recognize); SQL strings are
#'   parsed as `"duckdb"` unless a dialect is given.
#' @param schema Optional table schema used by the sqlglot engine to
#'   attribute unqualified columns to the right table and to expand
#'   `SELECT *`: a named list mapping table names to character vectors of
#'   column names, e.g. `list(orders = c("order_id", "amount"))`. Only
#'   relevant for SQL strings — the R engine reads exact provenance from
#'   the lazy query tree, and a lazy table that falls back to sqlglot
#'   harvests its schema from the database connection automatically.
#' @param labels Optional human-readable column labels: a named list
#'   mapping node ids to named character vectors, e.g.
#'   `list(orders = c(amount = "Order amount in USD"))`. Node ids are
#'   base table names, pipeline model names, or `"output"` for a single
#'   query's result. Labels ride on the matching nodes, show in
#'   [lineage_flow()] tooltips, land in [lineage_json()], and become each
#'   schema-facet field's `description` in [lineage_openlineage()].
#'   Entries here win over the two automatic sources: `label` attributes
#'   on a local frame's columns (the haven/labelled convention), and
#'   column comments read from the table's live database connection
#'   (duckdb and postgres; other backends are skipped quietly).
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
#'   [lineage_flow()], plus `metadata` recording the dialect, the engine
#'   used, node/edge counts, and a `models` map holding each model's
#'   analyzed SQL, engine, and dialect (one entry, keyed by the output
#'   table, for a single query).
#' @seealso [lineage_flow()] to render the result;
#'   `vignette("getting-started")` for a tour from simple pipelines to
#'   CTEs and multi-source columns.
#' @export
#' @examplesIf identical(Sys.getenv("NOT_CRAN"), "true") && dplyneage::has_sqlglot()
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
#' # Column labels ride along: database comments are read automatically,
#' # propagate to passthrough output columns, and a labels argument
#' # documents the computed ones. Hover a column in the diagram to see them.
#' invisible(DBI::dbExecute(
#'   con, "COMMENT ON COLUMN orders.customer_id IS 'Customer surrogate key'"
#' ))
#' tbl(con, "orders") |>
#'   group_by(customer_id) |>
#'   summarise(total = sum(amount, na.rm = TRUE)) |>
#'   extract_lineage(labels = list(output = c(total = "Total spent"))) |>
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
extract_lineage <- function(sql, dialect = NULL, schema = NULL, labels = NULL,
                            show_sql = FALSE,
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
      "dbplyr::tbl_lazy(df, name = \"df\") needs no database and is ",
      "enough for lineage; dbplyr::memdb_frame() or ",
      "copy_to(dbplyr::memdb(), df, name = \"df\") make the same ",
      "pipeline also collectable. See vignette(\"getting-started\").",
      call. = FALSE
    )
  }

  # A bare named list is a multi-model pipeline: each element is analyzed
  # on its own, then stitched into one graph by matching source tables to
  # model names
  if (is.list(sql) && !is.object(sql)) {
    return(extract_lineage_pipeline(
      sql, dialect, schema, labels, show_sql, engine, include_indirect
    ))
  }

  convert_lineage_to_graph(
    extract_lineage_data(
      sql, dialect, schema, labels, show_sql, engine, include_indirect
    )
  )
}

#' Run one query through the engine dispatch, returning lineage_data
#'
#' The single-query core of [extract_lineage()]: engine selection, R-engine
#' fallback, schema harvesting, and sqlglot extraction, without the final
#' conversion to a graph — so pipelines can stitch several results first.
#' @noRd
extract_lineage_data <- function(sql, dialect, schema, labels, show_sql, engine,
                                 include_indirect = FALSE) {
  labels <- normalize_labels(labels)
  is_lazy <- inherits(sql, "tbl_lazy")

  # Resolve dialect = NULL here rather than in extract_lineage() so each
  # model of a multi-model pipeline infers from its own connection
  if (is.null(dialect)) {
    dialect <- if (is_lazy) infer_dialect(dbplyr::remote_con(sql)) else "duckdb"
  }

  # Capture the connection while it is alive: the OpenLineage namespace
  # and column comments come from it, and nothing else about it survives
  # extraction. Column types ride along from whatever schema is in scope
  # when a branch returns — the user's, or the harvested one on the
  # sqlglot path (`schema` is read at call time, after any harvest).
  con <- if (is_lazy) dbplyr::remote_con(sql) else NULL
  namespace <- if (is_lazy) infer_namespace(con) else NULL
  finalize_lineage_data <- function(lineage_data) {
    if (!is.null(namespace)) {
      lineage_data$namespace <- namespace
    }
    types <- schema_types(schema)
    if (length(types) > 0) {
      lineage_data$column_types <- types
    }
    merged <- merge_label_maps(
      labels,
      harvest_all_column_labels(con, lineage_data$tables, dialect),
      lineage_data$column_labels %||% list()
    )
    if (length(merged) > 0) {
      lineage_data$column_labels <- merged
    }
    lineage_data
  }

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
    return(finalize_lineage_data(lineage_data))
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
      return(finalize_lineage_data(lineage_data))
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

  # Convert dbplyr query to SQL if needed; the connection captured above
  # lets us harvest the table schemas for accurate column attribution
  if (is_lazy) {
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
  finalize_lineage_data(
    extract_lineage_from_sql(sql, dialect, schema, include_indirect)
  )
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

# Connection classes of the common DBI drivers (including the odbc
# subclasses and dbplyr's simulate_*() connections, which share class
# names with the real drivers) mapped to sqlglot dialect names
dialect_by_class <- c(
  duckdb_connection = "duckdb",
  PqConnection = "postgres",
  PostgreSQLConnection = "postgres",
  RedshiftConnection = "redshift",
  MariaDBConnection = "mysql",
  MySQLConnection = "mysql",
  SQLiteConnection = "sqlite",
  BigQueryConnection = "bigquery",
  Snowflake = "snowflake",
  `Microsoft SQL Server` = "tsql",
  Oracle = "oracle",
  OraConnection = "oracle",
  Teradata = "teradata",
  `Spark SQL` = "spark",
  Hive = "hive",
  PrestoConnection = "presto",
  TrinoConnection = "trino"
)

#' Infer the sqlglot dialect a DBI connection speaks
#'
#' Unrecognized connections fall back to "duckdb", the historical
#' default.
#'
#' @param con A DBI connection
#' @return A sqlglot dialect string
#' @noRd
infer_dialect <- function(con) {
  hit <- intersect(class(con), names(dialect_by_class))
  if (length(hit) == 0) "duckdb" else unname(dialect_by_class[[hit[[1]]]])
}

#' Infer an OpenLineage dataset namespace for a DBI connection
#'
#' Follows the OpenLineage naming conventions where they exist
#' (postgres://host:port, mysql://host:port, ...). duckdb and sqlite have
#' no official entry, so file-backed databases get "<scheme>:<path>" and
#' in-memory ones the bare scheme. Returns NULL when nothing can be
#' inferred: simulated connections, unrecognized drivers, or drivers
#' whose dbGetInfo() lacks the fields the scheme needs.
#'
#' @param con A DBI connection
#' @return A namespace string, or NULL
#' @noRd
infer_namespace <- function(con) {
  # dbplyr's simulate_*() connections share driver classes with the real
  # drivers but hold no connection info
  if (inherits(con, "TestConnection")) {
    return(NULL)
  }
  hit <- intersect(class(con), names(dialect_by_class))
  if (length(hit) == 0) {
    return(NULL)
  }
  info <- tryCatch(DBI::dbGetInfo(con), error = function(e) NULL)
  ol_namespace_from_info(unname(dialect_by_class[[hit[[1]]]]), info)
}

#' Format an OpenLineage namespace from a dialect and dbGetInfo() fields
#' @noRd
ol_namespace_from_info <- function(dialect, info) {
  field <- function(name) {
    v <- info[[name]]
    if (is.null(v) || length(v) != 1 || is.na(v) || !nzchar(as.character(v))) {
      return(NULL)
    }
    as.character(v)
  }
  host_port <- function(scheme, host = field("host")) {
    port <- field("port")
    if (is.null(host) || !nzchar(host) || is.null(port)) {
      return(NULL)
    }
    paste0(scheme, "://", host, ":", port)
  }
  local_db <- function(scheme) {
    dbname <- field("dbname")
    if (is.null(dbname) || identical(dbname, ":memory:")) {
      return(scheme)
    }
    paste0(scheme, ":", dbname)
  }

  switch(
    dialect,
    postgres = host_port("postgres"),
    mysql = host_port("mysql"),
    tsql = host_port("mssql"),
    trino = host_port("trino"),
    redshift = host_port(
      "redshift",
      host = sub("\\.redshift\\.amazonaws\\.com$", "", field("host") %||% "")
    ),
    duckdb = local_db("duckdb"),
    sqlite = local_db("sqlite"),
    bigquery = "bigquery",
    snowflake = {
      server <- field("servername") %||% field("host")
      if (is.null(server)) {
        NULL
      } else {
        paste0(
          "snowflake://",
          sub("\\.snowflakecomputing\\.com$", "", server)
        )
      }
    },
    NULL
  )
}

#' Harvest Table Schemas from a Database Connection
#'
#' Lists the columns of each base table referenced by the query so sqlglot
#' can resolve unqualified columns and expand `*`, with their database
#' types when a zero-row probe query can report them. Returns NULL if the
#' schema cannot be determined (lineage extraction still works, with
#' reduced attribution accuracy).
#'
#' @param con A DBI connection
#' @param sql SQL query string
#' @param dialect SQL dialect
#' @return Named list mapping table names to named lists of column types
#'   (or bare character vectors of columns when types are unavailable),
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
      harvest_column_types(con, ref),
      error = function(e) NULL
    )
    if (is.null(fields)) {
      fields <- tryCatch(
        DBI::dbListFields(con, ref),
        error = function(e) NULL
      )
    }
    if (!is.null(fields)) {
      schema[[tbl$name]] <- fields
    }
  }

  if (length(schema) == 0) NULL else schema
}

#' The typed entries of a schema, as {table: named chr of col -> type}
#'
#' A schema maps tables to either bare column vectors or named col ->
#' type entries (user-supplied or harvested); only the latter carry
#' types worth propagating.
#' @noRd
schema_types <- function(schema) {
  if (is.null(schema)) {
    return(list())
  }
  types <- list()
  for (tbl in names(schema)) {
    cols <- schema[[tbl]]
    if (is.list(cols)) {
      cols <- unlist(cols)
    }
    nms <- names(cols)
    if (is.null(nms) || any(!nzchar(nms))) next
    types[[tbl]] <- stats::setNames(as.character(cols), nms)
  }
  types
}

#' One node's entries of a {table: named chr} map (types or labels),
#' when the extraction captured any
#' @noRd
spec_types <- function(column_types, table, columns) {
  types <- column_types[[table]]
  if (is.null(types)) {
    return(NULL)
  }
  hit <- types[intersect(as.character(columns), names(types))]
  if (length(hit) == 0) NULL else hit
}

#' Validate and normalize labels= to {table: named chr of col -> label}
#' @noRd
normalize_labels <- function(labels) {
  if (is.null(labels)) {
    return(list())
  }
  bad <- !is.list(labels) || is.null(names(labels)) ||
    any(!nzchar(names(labels)))
  if (!bad) {
    bad <- !all(vapply(labels, function(x) {
      x <- unlist(x)
      is.character(x) && length(x) > 0 && !is.null(names(x)) &&
        all(nzchar(names(x)))
    }, logical(1)))
  }
  if (bad) {
    stop(
      "labels must be a named list mapping tables to named character ",
      "vectors of column labels, e.g. ",
      "list(orders = c(amount = \"Order amount in USD\")).",
      call. = FALSE
    )
  }
  lapply(labels, function(x) {
    x <- unlist(x)
    x[!is.na(x) & nzchar(x)]
  })
}

#' Merge {table: named chr} maps; earlier maps win per column
#' @noRd
merge_label_maps <- function(...) {
  out <- list()
  for (m in list(...)) {
    for (tbl in names(m)) {
      new_cols <- setdiff(names(m[[tbl]]), names(out[[tbl]]))
      out[[tbl]] <- c(out[[tbl]], m[[tbl]][new_cols])
    }
  }
  out
}

#' Column names and types from a zero-row probe of one table
#' @noRd
harvest_column_types <- function(con, ref) {
  res <- DBI::dbSendQuery(
    con,
    paste0("SELECT * FROM ", DBI::dbQuoteIdentifier(con, ref), " WHERE 1 = 0")
  )
  on.exit(DBI::dbClearResult(res))
  info <- DBI::dbColumnInfo(res)
  if (!is.data.frame(info) || nrow(info) == 0 ||
    !all(c("name", "type") %in% names(info))) {
    return(NULL)
  }
  # Some drivers (RPostgres) expose the database type as .typname; the
  # DBI-standard type column holds the R type
  type <- if (".typname" %in% names(info)) info$.typname else info$type
  stats::setNames(as.list(as.character(type)), info$name)
}

#' Column comments of one table, as a named chr of col -> comment
#'
#' Comment catalogs are per-backend, so this dispatches on the dialect
#' string; dialects without one (sqlite, and anything unlisted) return
#' NULL. Errors are the caller's to swallow.
#' @noRd
harvest_column_labels <- function(con, table, dialect) {
  parts <- strsplit(table, ".", fixed = TRUE)[[1]]
  sql <- switch(
    dialect,
    duckdb = {
      # An unqualified name filters on current_schema() so same-named
      # tables in other schemas don't bleed in
      schema_filter <- if (length(parts) > 1) {
        DBI::dbQuoteString(con, parts[[length(parts) - 1]])
      } else {
        "current_schema()"
      }
      paste0(
        "SELECT column_name, comment FROM duckdb_columns() ",
        "WHERE table_name = ",
        DBI::dbQuoteString(con, parts[[length(parts)]]),
        " AND schema_name = ", schema_filter
      )
    },
    postgres = ,
    redshift = paste0(
      # The quoted-identifier-as-regclass literal resolves search_path
      # and schema qualification the same way the query itself would
      "SELECT a.attname AS column_name, ",
      "pg_catalog.col_description(a.attrelid, a.attnum) AS comment ",
      "FROM pg_catalog.pg_attribute a WHERE a.attrelid = ",
      DBI::dbQuoteString(con, as.character(DBI::dbQuoteIdentifier(
        con,
        if (length(parts) > 1) DBI::Id(parts) else table
      ))),
      "::regclass AND a.attnum > 0 AND NOT a.attisdropped"
    ),
    NULL
  )
  if (is.null(sql)) {
    return(NULL)
  }
  res <- DBI::dbGetQuery(con, sql)
  keep <- !is.na(res$comment) & nzchar(res$comment)
  if (!any(keep)) {
    return(NULL)
  }
  stats::setNames(as.character(res$comment[keep]), res$column_name[keep])
}

#' Column comments for every base table of an extraction
#'
#' Returns {table: named chr of col -> comment}, shaped like
#' column_types. Failures stay silent — lineage never breaks because a
#' comment catalog was unreachable — and dbplyr's simulate_*()
#' connections are skipped like infer_namespace() skips them.
#' @noRd
harvest_all_column_labels <- function(con, tables, dialect) {
  if (is.null(con) || inherits(con, "TestConnection") ||
    !requireNamespace("DBI", quietly = TRUE)) {
    return(list())
  }
  out <- list()
  for (tbl in tables %||% list()) {
    labs <- tryCatch(
      harvest_column_labels(con, tbl$name, dialect),
      error = function(e) NULL
    )
    if (length(labs) > 0) {
      out[[tbl$name]] <- labs
    }
  }
  out
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
    columns <- unlist(tables_with_columns[[table_name]])
    list(
      id = table_name,
      columns = columns,
      type = "source",
      layer = 0L,
      types = spec_types(lineage_data$column_types %||% list(), table_name, columns),
      labels = spec_types(
        lineage_data$column_labels %||% list(), table_name, columns
      )
    )
  })
  if (length(output_columns) > 0) {
    # A labels= entry keyed by the output table documents computed
    # columns the identity-edge propagation can't reach
    specs[[length(specs) + 1]] <- list(
      id = output_table,
      columns = output_columns,
      type = "target",
      layer = 1L,
      labels = spec_types(
        lineage_data$column_labels %||% list(), output_table, output_columns
      )
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
  # output column — dashed, and skipped where a direct edge already
  # exists. A pair reached through several kinds keeps one edge
  # recording all of them
  indirect_at <- integer()
  for (source in indirect) {
    for (output_column in output_columns) {
      key <- paste0(
        source_table_name(source), ".", source$column_name,
        "->", output_column
      )
      if (key %in% edge_keys) next
      at <- indirect_at[key]
      if (!is.na(at)) {
        edges[[at]] <- add_indirect_kind(edges[[at]], source$kind)
        next
      }
      edges[[length(edges) + 1]] <-
        indirect_edge_for(source, output_table, output_column)
      indirect_at[[key]] <- length(edges)
    }
  }

  # Metadata takes the same shape as multi-model pipelines: a one-entry
  # models map keyed by the output table, so consumers of the committed
  # JSON artifact read per-model SQL one way for both
  engine <- if (is.null(lineage_data$engine)) "sqlglot" else lineage_data$engine
  model <- list(
    sql = lineage_data$sql,
    engine = engine,
    dialect = lineage_data$dialect
  )
  # Only when captured: a NULL entry would serialize to JSON as {}
  if (!is.null(lineage_data$namespace)) {
    model$namespace <- lineage_data$namespace
  }
  models <- list(model)
  names(models) <- output_table

  nodes <- propagate_column_metadata(nodes, edges)

  structure(
    list(
      nodes = nodes,
      edges = edges,
      metadata = list(
        dialect = lineage_data$dialect,
        engine = engine,
        models = models,
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
