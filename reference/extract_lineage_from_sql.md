# Extract Lineage from SQL using sqlglot

Internal function that calls the bundled Python module (built on
sqlglot.lineage) to parse SQL and trace each output column to its source
columns.

## Usage

``` r
extract_lineage_from_sql(
  sql,
  dialect = "duckdb",
  schema = NULL,
  include_indirect = FALSE
)
```

## Arguments

- sql:

  SQL query string

- dialect:

  SQL dialect

- schema:

  Optional named list mapping table names to column vectors

- include_indirect:

  Also collect filter/join/group/sort columns?

## Value

List containing tables, columns, sql, and dialect
