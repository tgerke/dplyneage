# Export lineage as GraphML

Serializes a lineage object to
[GraphML](http://graphml.graphdrawing.org/), the XML graph format read
by igraph, Gephi, yEd, and most other graph tools. Each table column
becomes a node (id `"table.column"`, duplicated in a `name` attribute so
igraph picks it up as the vertex name) with `table`, `column`, and
`node_type` attributes; each column-level edge becomes a directed edge.
That granularity is what makes the export useful downstream:
`igraph::subcomponent(g, "output.total", mode = "in")` lists every
source column feeding an output, and Gephi can color the graph by
`table`.

## Usage

``` r
lineage_graphml(lineage, path = NULL)
```

## Arguments

- lineage:

  The result of
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md),
  or any list with `nodes` and `edges` built with
  [`create_table_node()`](https://tgerke.github.io/dplyneage/reference/create_table_node.md)
  and
  [`create_column_edge()`](https://tgerke.github.io/dplyneage/reference/create_column_edge.md).

- path:

  Optional file to write the GraphML to. When supplied, the string is
  returned invisibly.

## Value

A string containing the GraphML document.

## See also

[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
to compute lineage automatically

Other lineage exporters:
[`lineage_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md)

## Examples

``` r
lineage <- list(
  nodes = list(
    create_table_node("orders", c("order_id", "amount")),
    create_table_node("daily_totals", "total", table_type = "target")
  ),
  edges = list(
    create_column_edge("orders", "amount", "daily_totals", "total")
  )
)
cat(lineage_graphml(lineage))
#> <?xml version="1.0" encoding="UTF-8"?>
#> <graphml xmlns="http://graphml.graphdrawing.org/xmlns"
#>          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
#>          xsi:schemaLocation="http://graphml.graphdrawing.org/xmlns http://graphml.graphdrawing.org/xmlns/1.0/graphml.xsd">
#>   <key id="name" for="node" attr.name="name" attr.type="string"/>
#>   <key id="table" for="node" attr.name="table" attr.type="string"/>
#>   <key id="column" for="node" attr.name="column" attr.type="string"/>
#>   <key id="node_type" for="node" attr.name="node_type" attr.type="string"/>
#>   <graph id="lineage" edgedefault="directed">
#>     <node id="orders.order_id">
#>       <data key="name">orders.order_id</data>
#>       <data key="table">orders</data>
#>       <data key="column">order_id</data>
#>       <data key="node_type">source</data>
#>     </node>
#>     <node id="orders.amount">
#>       <data key="name">orders.amount</data>
#>       <data key="table">orders</data>
#>       <data key="column">amount</data>
#>       <data key="node_type">source</data>
#>     </node>
#>     <node id="daily_totals.total">
#>       <data key="name">daily_totals.total</data>
#>       <data key="table">daily_totals</data>
#>       <data key="column">total</data>
#>       <data key="node_type">target</data>
#>     </node>
#>     <edge source="orders.amount" target="daily_totals.total"/>
#>   </graph>
#> </graphml>

# Round-trip through igraph for ancestry queries
path <- tempfile(fileext = ".graphml")
lineage_graphml(lineage, path = path)
g <- igraph::read_graph(path, format = "graphml")
igraph::subcomponent(g, "daily_totals.total", mode = "in")
#> + 2/3 vertices, named, from c429f15:
#> [1] daily_totals.total orders.amount     
```
