# Harvest table schemas from a database connection

Lists the columns of each base table referenced by the query so sqlglot
can resolve unqualified columns and expand `*`, with their database
types when a zero-row probe query can report them. Returns NULL if the
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

Named list mapping table names to named lists of column types (or bare
character vectors of columns when types are unavailable), or NULL
