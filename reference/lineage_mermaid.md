# Export lineage as a Mermaid flowchart

Serializes a lineage object to [Mermaid](https://mermaid.js.org/)
flowchart text. Mermaid renders natively in GitHub markdown, Quarto, and
most documentation tools, so this is the exporter to reach for when
lineage should live *in the docs*: paste the output into a
```` ```mermaid ```` code fence and the diagram renders with no R, no
htmlwidget, and no JavaScript bundle.

## Usage

``` r
lineage_mermaid(lineage, path = NULL)
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

  Optional file to write the Mermaid text to. When supplied, the string
  is returned invisibly.

## Value

A string containing the Mermaid flowchart definition.

## Details

Each table becomes a subgraph containing its columns, colored by table
type with the same palette as
[`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md).
Non-identity edges are labeled with the column's defining expression,
and indirect edges (from `extract_lineage(include_indirect = TRUE)`)
draw dashed.

## See also

[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
to compute lineage automatically

Other lineage exporters:
[`lineage_graphml()`](https://tgerke.github.io/dplyneage/reference/lineage_graphml.md),
[`lineage_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md),
[`lineage_openlineage()`](https://tgerke.github.io/dplyneage/reference/lineage_openlineage.md)

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
cat(lineage_mermaid(lineage))
#> flowchart LR
#>   subgraph orders["orders"]
#>     orders_order_id["order_id"]
#>     orders_amount["amount"]
#>   end
#>   subgraph daily_totals["daily_totals"]
#>     daily_totals_total["total"]
#>   end
#>   orders_amount --> daily_totals_total
#>   classDef source fill:#f0f7ff,stroke:#3b82f6,color:#1d4ed8
#>   classDef transform fill:#fef3f2,stroke:#f59e0b,color:#d97706
#>   classDef target fill:#f0fdf4,stroke:#10b981,color:#059669
#>   class orders source
#>   class daily_totals target

# Ready to paste into a GitHub README or Quarto document:
cat("```mermaid\n", lineage_mermaid(lineage), "```\n", sep = "")
#> ```mermaid
#> flowchart LR
#>   subgraph orders["orders"]
#>     orders_order_id["order_id"]
#>     orders_amount["amount"]
#>   end
#>   subgraph daily_totals["daily_totals"]
#>     daily_totals_total["total"]
#>   end
#>   orders_amount --> daily_totals_total
#>   classDef source fill:#f0f7ff,stroke:#3b82f6,color:#1d4ed8
#>   classDef transform fill:#fef3f2,stroke:#f59e0b,color:#d97706
#>   classDef target fill:#f0fdf4,stroke:#10b981,color:#059669
#>   class orders source
#>   class daily_totals target
#> ```
```
