#' Extract Column Lineage from SQL Query
#'
#' Uses sqlglot to parse SQL and extract column-level lineage information.
#' Works seamlessly in a pipeline - just pipe your dplyr query directly to this function.
#'
#' @param sql A SQL query string or a dbplyr lazy table (tbl_lazy). 
#'   When using in a pipe with dplyr/dbplyr, the query is automatically converted to SQL.
#' @param dialect SQL dialect (e.g., "duckdb", "postgres", "mysql", "snowflake").
#'   Default: "duckdb"
#' @param show_sql If TRUE, prints the SQL query being analyzed. Default: FALSE
#' @return A list containing nodes and edges for lineage visualization
#' @export
#' @examples
#' \dontrun{
#' library(dplyr)
#' library(dbplyr)
#' library(duckdb)
#' 
#' # Connect to DuckDB
#' con <- dbConnect(duckdb::duckdb(), ":memory:")
#' 
#' # Method 1: Pass a dplyr pipeline directly (cleanest!)
#' tbl(con, "customers") |>
#'   select(customer_id, name, email) |>
#'   left_join(tbl(con, "orders"), by = "customer_id") |>
#'   group_by(customer_id, name) |>
#'   summarise(total_spent = sum(amount, na.rm = TRUE)) |>
#'   extract_lineage() |>
#'   lineage_flow(height = "600px")
#' 
#' # Method 2: Store the query first
#' query <- tbl(con, "customers") |>
#'   select(customer_id, name, email) |>
#'   left_join(tbl(con, "orders"), by = "customer_id")
#' 
#' lineage <- extract_lineage(query)
#' lineage_flow(lineage)
#' 
#' # Method 3: Use raw SQL
#' sql <- "SELECT id, name FROM customers"
#' lineage <- extract_lineage(sql)
#' lineage_flow(lineage)
#' 
#' dbDisconnect(con)
#' }
extract_lineage <- function(sql, dialect = "duckdb", show_sql = FALSE) {
  # Ensure sqlglot is available
  if (!has_sqlglot()) {
    stop(
      "Python package 'sqlglot' is required for lineage extraction.\n",
      "Install it with: install_sqlglot()",
      call. = FALSE
    )
  }
  
  # Convert dbplyr query to SQL if needed
  if (inherits(sql, "tbl_lazy")) {
    sql <- get_sql_from_dplyr(sql)
  }
  
  # Ensure we have a character string
  if (!is.character(sql)) {
    stop("sql must be a character string or a dbplyr lazy table", call. = FALSE)
  }
  
  # Optionally show the SQL being analyzed
  if (show_sql) {
    cat("Analyzing SQL:\n")
    cat(sql, "\n\n")
  }
  
  # Extract lineage using sqlglot
  lineage_data <- extract_lineage_from_sql(sql, dialect)
  
  # Convert to nodes and edges format
  convert_lineage_to_graph(lineage_data)
}

#' Get SQL String from dplyr Query
#'
#' Converts a dbplyr lazy table to SQL string using show_query
#'
#' @param query A dbplyr lazy table (tbl_lazy)
#' @return Character string containing SQL query
#' @keywords internal
get_sql_from_dplyr <- function(query) {
  if (!inherits(query, "tbl_lazy")) {
    stop("query must be a dbplyr lazy table (tbl_lazy)", call. = FALSE)
  }
  
  # Get SQL from dbplyr
  sql_obj <- dbplyr::sql_render(query)
  
  # Convert to character
  as.character(sql_obj)
}

#' Extract Lineage from SQL using sqlglot
#'
#' Internal function that calls Python sqlglot to parse SQL and extract lineage
#'
#' @param sql SQL query string
#' @param dialect SQL dialect
#' @return List containing raw lineage data from sqlglot
#' @keywords internal
extract_lineage_from_sql <- function(sql, dialect = "duckdb") {
  # Get sqlglot module (configured in .onLoad via py_require)
  sqlglot <- .dplyneage$sqlglot
  
  tryCatch({
    # Parse the SQL
    parsed <- sqlglot$parse_one(sql, dialect = dialect)
    
    # Extract table and column references directly from the AST
    # This is more reliable than using sqlglot.lineage module
    tables <- extract_table_references(parsed)
    columns <- extract_column_references(parsed)
    
    list(
      tables = tables,
      columns = columns,
      sql = sql,
      dialect = dialect
    )
    
  }, error = function(e) {
    stop(
      "Failed to extract lineage from SQL.\n",
      "SQL: ", sql, "\n",
      "Error: ", conditionMessage(e),
      call. = FALSE
    )
  })
}

#' Process sqlglot Lineage Result
#'
#' Converts sqlglot lineage objects to R data structures
#'
#' @param lineage_result Result from sqlglot.lineage.lineage()
#' @param sql Original SQL query
#' @param dialect SQL dialect
#' @return List with structured lineage information
#' @keywords internal
process_sqlglot_lineage <- function(lineage_result, sql, dialect) {
  # This function is deprecated - keeping for backwards compatibility
  # Now we extract lineage directly in extract_lineage_from_sql
  lineage_result
}

#' Extract Table References from Parsed SQL
#'
#' @param parsed_sql Parsed SQL expression from sqlglot
#' @return List of table references
#' @keywords internal
extract_table_references <- function(parsed_sql) {
  # Use Python to walk the AST and find table references
  py_code <- reticulate::py_run_string("
def extract_tables(expression):
    '''Extract table references from sqlglot expression'''
    from sqlglot import exp
    tables = []
    for table in expression.find_all(exp.Table):
        table_name = table.name
        # Get alias if it exists
        alias = None
        if hasattr(table, 'alias') and table.alias:
            alias = table.alias
        tables.append({
            'name': str(table_name),
            'alias': str(alias) if alias else None,
            'qualified_name': table.sql()
        })
    return tables
  ", convert = TRUE)
  
  py_code$extract_tables(parsed_sql)
}

#' Extract Column References from Parsed SQL
#'
#' @param parsed_sql Parsed SQL expression from sqlglot
#' @return List of column references with lineage
#' @keywords internal
extract_column_references <- function(parsed_sql) {
  # Enhanced extraction with subquery alias resolution
  py_code <- reticulate::py_run_string("
def extract_columns(expression):
    '''Extract column references with subquery tracing'''
    from sqlglot import exp
    from sqlglot.optimizer import qualify
    
    columns = []
    
    # Find all base tables
    base_tables = []
    table_aliases = {}
    for table in expression.find_all(exp.Table):
        table_name = str(table.name)
        if table_name not in base_tables:
            base_tables.append(table_name)
        table_aliases[table_name] = table_name
        
        if hasattr(table.parent, 'alias') and table.parent.alias:
            alias = str(table.parent.alias)
            table_aliases[alias] = table_name
    
    # Qualify the SQL
    try:
        qualified = qualify.qualify(
            expression,
            validate_qualify_columns=False,
            identify=True
        )
    except Exception:
        qualified = expression
    
    # Build column mapping by analyzing inner SELECTs
    # Map: column_name -> table_name
    column_to_table = {}
    
    # Also build subquery mapping: subquery_alias.column -> base_table
    subquery_column_map = {}
    
    all_selects = list(qualified.find_all(exp.Select))
    if not all_selects:
        return columns
    
    # Process inner SELECTs to build mappings
    for select in all_selects[1:]:
        # Check if this is a subquery with an alias
        subquery_alias = None
        if isinstance(select.parent, exp.Subquery) and select.parent.alias:
            subquery_alias = str(select.parent.alias)
        
        # Find all tables in this SELECT's FROM clause
        select_tables = []
        for table in select.find_all(exp.Table):
            t_name = str(table.name)
            if t_name not in select_tables:
                select_tables.append(t_name)
        
        # Track which tables are used in Star expressions
        star_tables = set()
        for proj in select.expressions:
            # Check if this projection is or contains a Star
            stars = list(proj.find_all(exp.Star))
            if stars:
                # Check the projection's columns for table references
                for col in proj.find_all(exp.Column):
                    if hasattr(col, 'table') and col.table:
                        star_tables.add(str(col.table))
        
        # Process each projection
        for proj in select.expressions:
            output_name = proj.alias_or_name
            
            # Handle Star expressions (e.g., customers.*)
            stars = list(proj.find_all(exp.Star))
            if stars:
                for star in stars:
                    if hasattr(star, 'table') and star.table:
                        star_table = str(star.table)
                        actual_table = table_aliases.get(star_table, star_table)
                        # Note: this table has all its columns, but we don't know which ones
                        # We'll handle this when we encounter specific column references
                        if subquery_alias and actual_table in base_tables:
                            # Mark that this subquery includes this table's columns
                            # Store it for later matching
                            subquery_column_map[f'{subquery_alias}.*'] = actual_table
            
            # Handle regular columns
            cols = list(proj.find_all(exp.Column))
            for col in cols:
                col_name = str(col.name)
                table_ref = None
                
                if hasattr(col, 'table') and col.table:
                    table_id = str(col.table)
                    table_ref = table_aliases.get(table_id, table_id)
                else:
                    # Column has no explicit table - use heuristic
                    # Prefer non-star tables (columns from joined tables)
                    non_star_tables = [t for t in select_tables if t not in star_tables]
                    if non_star_tables:
                        table_ref = non_star_tables[0]
                    elif select_tables:
                        table_ref = select_tables[0]
                
                if table_ref and table_ref in base_tables:
                    column_to_table[output_name] = table_ref
                    column_to_table[col_name] = table_ref
                    
                    if subquery_alias:
                        subquery_column_map[f'{subquery_alias}.{output_name}'] = table_ref
                        subquery_column_map[f'{subquery_alias}.{col_name}'] = table_ref
    
    # Process the outermost SELECT
    outermost = all_selects[0]
    for projection in outermost.expressions:
        col_info = {
            'output_name': projection.alias_or_name,
            'expression': projection.sql(),
            'sources': []
        }
        
        seen = set()
        for col in projection.find_all(exp.Column):
            col_name = str(col.name)
            table_ref = None
            
            # Check if column references a subquery
            if hasattr(col, 'table') and col.table:
                table_id = str(col.table)
                
                # Try to resolve through subquery mapping
                lookup_key = f'{table_id}.{col_name}'
                if lookup_key in subquery_column_map:
                    table_ref = subquery_column_map[lookup_key]
                elif table_id in table_aliases and table_aliases[table_id] in base_tables:
                    table_ref = table_aliases[table_id]
                else:
                    # Check if we saw this column in our mapping
                    if col_name in column_to_table:
                        table_ref = column_to_table[col_name]
                    # Check for star table hint
                    elif f'{table_id}.*' in subquery_column_map:
                        table_ref = subquery_column_map[f'{table_id}.*']
            else:
                # No table specified
                if col_name in column_to_table:
                    table_ref = column_to_table[col_name]
            
            # Fallback
            if not table_ref or table_ref not in base_tables:
                table_ref = base_tables[0] if base_tables else None
            
            source_key = f'{table_ref}.{col_name}'
            if source_key not in seen:
                col_info['sources'].append({
                    'column_name': col_name,
                    'table': table_ref
                })
                seen.add(source_key)
        
        columns.append(col_info)
    
    return columns
  ", convert = TRUE)
  
  py_code$extract_columns(parsed_sql)
}

#' Convert Lineage Data to Graph Structure
#'
#' Converts lineage information to nodes and edges for visualization
#'
#' @param lineage_data Processed lineage data
#' @return List with nodes and edges
#' @keywords internal
convert_lineage_to_graph <- function(lineage_data) {
  tables <- lineage_data$tables
  columns <- lineage_data$columns
  
  # Get list of actual base table names for fallback
  base_table_names <- sapply(tables, function(t) t$name)
  
  # Create nodes for each table
  nodes <- list()
  
  # Group columns by table
  tables_with_columns <- list()
  
  for (col in columns) {
    output_table <- "output"  # Default output table name
    
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
      
      # If table is still NULL/NA and we have exactly one base table, use it as fallback
      # (This handles simple single-table queries)
      if (is.null(table_name) || is.na(table_name) || table_name == "NULL") {
        if (length(base_table_names) == 1) {
          table_name <- base_table_names[1]
        } else {
          table_name <- "unknown"
        }
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
  x_pos <- 0
  y_pos <- 0
  y_spacing <- 200
  x_spacing <- 400
  
  source_tables <- setdiff(names(tables_with_columns), "output")
  
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
  if ("output" %in% names(tables_with_columns)) {
    cols <- unlist(tables_with_columns[["output"]])
    if (length(cols) > 0) {
      nodes[[length(nodes) + 1]] <- create_table_node(
        table_name = "output",
        columns = cols,
        x = x_pos + x_spacing,
        y = y_pos + (length(source_tables) - 1) * y_spacing / 2,
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
          to_table = "output",
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
