# Harvest Table Schemas from a Database Connection

Lists the columns of each base table referenced by the query so sqlglot
can resolve unqualified columns and expand `*`. Returns NULL if the
schema cannot be determined (lineage extraction still works, with
reduced attribution accuracy).

## Usage

``` r
harvest_schema(con, sql, dialect = "duckdb")
```

## Arguments

- con:

  A DBI connection

- sql:

  SQL query string

- dialect:

  SQL dialect

## Value

Named list mapping table names to character vectors of columns, or NULL
