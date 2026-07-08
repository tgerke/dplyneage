# Create a table node for a lineage diagram

Builds one table, with its columns, for lineage diagrams rendered by
[`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md).
Use this together with
[`create_column_edge()`](https://tgerke.github.io/dplyneage/reference/create_column_edge.md)
when you want full control over the diagram instead of extracting
lineage automatically.

## Usage

``` r
create_table_node(table_name, columns, x = 0, y = 0, table_type = "source")
```

## Arguments

- table_name:

  Name shown in the node header. Also used as the node id, so it must be
  unique within a diagram.

- columns:

  Character vector of column names listed in the node. Each column gets
  connection handles that edges can attach to.

- x, y:

  Position of the node on the canvas, in pixels. Nodes remain draggable,
  so these only set the starting layout.

- table_type:

  One of `"source"` (blue), `"transform"` (orange), or `"target"`
  (green). The colors follow the conventions used by tools like dbt and
  SQLMesh.

## Value

A node list ready to pass to
[`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md)

## See also

[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
to build nodes and edges automatically

Other manual lineage builders:
[`create_column_edge()`](https://tgerke.github.io/dplyneage/reference/create_column_edge.md),
[`lineage_example()`](https://tgerke.github.io/dplyneage/reference/lineage_example.md)

## Examples

``` r
create_table_node(
  table_name = "customers",
  columns = c("id", "name", "email"),
  table_type = "source"
)
#> $id
#> [1] "customers"
#> 
#> $type
#> [1] "tableNode"
#> 
#> $data
#> $data$label
#> [1] "customers"
#> 
#> $data$columns
#> [1] "id"    "name"  "email"
#> 
#> $data$tableType
#> [1] "source"
#> 
#> $data$colors
#> $data$colors$bg
#> [1] "#f0f7ff"
#> 
#> $data$colors$border
#> [1] "#3b82f6"
#> 
#> $data$colors$header
#> [1] "#1d4ed8"
#> 
#> 
#> 
#> $position
#> $position$x
#> [1] 0
#> 
#> $position$y
#> [1] 0
#> 
#> 
#> $draggable
#> [1] TRUE
#> 
#> $sourcePosition
#> [1] "right"
#> 
#> $targetPosition
#> [1] "left"
#> 
```
