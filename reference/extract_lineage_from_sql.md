# Extract Lineage from SQL using sqlglot

Internal function that calls the bundled Python module (built on
sqlglot.lineage) to parse SQL and trace each output column to its source
columns.

## Usage

``` r
extract_lineage_from_sql(sql, dialect = "duckdb", schema = NULL)
```

## Arguments

- sql:

  SQL query string

- dialect:

  SQL dialect

- schema:

  Optional named list mapping table names to column vectors

## Value

List containing tables, columns, sql, and dialect
