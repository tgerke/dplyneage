# Render an interactive column lineage diagram

Draws a lineage graph with [React Flow](https://reactflow.dev/): tables
as draggable nodes, column-to-column edges, and zoom/pan controls. Pass
the result of
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
directly (it is detected automatically, so piping works), or build
`nodes` and `edges` yourself with
[`create_table_node()`](https://tgerke.github.io/dplyneage/reference/create_table_node.md)
and
[`create_column_edge()`](https://tgerke.github.io/dplyneage/reference/create_column_edge.md).

## Usage

``` r
lineage_flow(
  nodes = list(),
  edges = list(),
  width = NULL,
  height = NULL,
  elementId = NULL,
  minimap = FALSE,
  legend = TRUE,
  theme = c("light", "dark", "auto"),
  export_button = TRUE
)
```

## Arguments

- nodes:

  The output of
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md),
  or a list of nodes created with
  [`create_table_node()`](https://tgerke.github.io/dplyneage/reference/create_table_node.md).

- edges:

  A list of edges created with
  [`create_column_edge()`](https://tgerke.github.io/dplyneage/reference/create_column_edge.md).
  Ignored when `nodes` is an
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  result, which carries its own edges.

- width, height:

  CSS dimensions of the widget, e.g. `"100%"` or `"600px"`. Default to
  full width and 600px tall.

- elementId:

  Explicit HTML element id for the widget. Usually left `NULL` so one is
  generated.

- minimap:

  If `TRUE`, draws a pannable overview map in the corner. Off by
  default; it earns its space on large multi-model graphs.

- legend:

  If `TRUE` (the default), overlays a small legend naming the node
  colors and edge styles present in the graph.

- theme:

  `"light"` (the default), `"dark"`, or `"auto"`, which follows the
  viewer's `prefers-color-scheme`. That is the operating-system setting,
  not the theme of a surrounding Quarto or R Markdown document, so
  documents rendered dark should pass `theme = "dark"` explicitly.

- export_button:

  If `TRUE` (the default), the zoom controls gain a button that
  downloads the diagram as a PNG.

## Value

An htmlwidget that prints in the RStudio viewer, R Markdown / Quarto
documents, and Shiny apps.

## Details

Clicking a column isolates its trace cone (the transitive upstream and
downstream subgraph) and dims everything else; clicking it again,
clicking the background, or pressing Escape releases it. In Shiny, the
traced column is reported as `input$<outputId>_selected`, a list with
`table` and `column` entries (`NULL` when nothing is traced).

Hovering a column shows a small card with its captured type and label
(see
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)'s
`schema` and `labels` arguments); columns with neither stay quiet. The
static SVG fallback shows the same information through native browser
tooltips.

## See also

[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
to compute lineage automatically;
[`lineage_flowOutput()`](https://tgerke.github.io/dplyneage/reference/lineage_flow-shiny.md)
and
[`renderLineageFlow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow-shiny.md)
for Shiny.

## Examples

``` r
# Build a small diagram by hand
nodes <- list(
  create_table_node("orders", c("order_id", "amount"), x = 0, y = 0),
  create_table_node("daily_totals", c("total"),
    x = 400, y = 0, table_type = "target"
  )
)
edges <- list(
  create_column_edge("orders", "amount", "daily_totals", "total",
    label = "SUM()", animated = TRUE
  )
)
lineage_flow(nodes, edges)

{"x":{"nodes":[{"id":"orders","type":"tableNode","data":{"label":"orders","columns":["order_id","amount"],"tableType":"source","colors":{"bg":"#f0f7ff","border":"#3b82f6","header":"#1d4ed8"}},"position":{"x":0,"y":0},"draggable":true,"sourcePosition":"right","targetPosition":"left"},{"id":"daily_totals","type":"tableNode","data":{"label":"daily_totals","columns":"total","tableType":"target","colors":{"bg":"#f0fdf4","border":"#10b981","header":"#059669"}},"position":{"x":400,"y":0},"draggable":true,"sourcePosition":"right","targetPosition":"left"}],"edges":[{"id":"e_orders.amount_to_daily_totals.total","source":"orders","target":"daily_totals","sourceHandle":"amount","targetHandle":"total","animated":true,"style":{"stroke":"#64748b","strokeWidth":2},"label":"SUM()","labelStyle":{"fill":"#64748b","fontWeight":500,"fontSize":11},"labelBgStyle":{"fill":"#ffffff","fillOpacity":0.9}}],"options":{"minimap":false,"legend":true,"theme":"light","exportButton":true}},"evals":[],"jsHooks":[]}
# Dark theme with the overview map
lineage_flow(nodes, edges, theme = "dark", minimap = TRUE)

{"x":{"nodes":[{"id":"orders","type":"tableNode","data":{"label":"orders","columns":["order_id","amount"],"tableType":"source","colors":{"bg":"#f0f7ff","border":"#3b82f6","header":"#1d4ed8"}},"position":{"x":0,"y":0},"draggable":true,"sourcePosition":"right","targetPosition":"left"},{"id":"daily_totals","type":"tableNode","data":{"label":"daily_totals","columns":"total","tableType":"target","colors":{"bg":"#f0fdf4","border":"#10b981","header":"#059669"}},"position":{"x":400,"y":0},"draggable":true,"sourcePosition":"right","targetPosition":"left"}],"edges":[{"id":"e_orders.amount_to_daily_totals.total","source":"orders","target":"daily_totals","sourceHandle":"amount","targetHandle":"total","animated":true,"style":{"stroke":"#64748b","strokeWidth":2},"label":"SUM()","labelStyle":{"fill":"#64748b","fontWeight":500,"fontSize":11},"labelBgStyle":{"fill":"#ffffff","fillOpacity":0.9}}],"options":{"minimap":true,"legend":true,"theme":"dark","exportButton":true}},"evals":[],"jsHooks":[]}# Or pipe from extract_lineage()
extract_lineage("SELECT id, name FROM customers") |>
  lineage_flow()

{"x":{"nodes":[{"id":"customers","type":"tableNode","data":{"label":"customers","columns":["id","name"],"tableType":"source","colors":{"bg":"#f0f7ff","border":"#3b82f6","header":"#1d4ed8"}},"position":{"x":0,"y":0},"draggable":true,"sourcePosition":"right","targetPosition":"left"},{"id":"output","type":"tableNode","data":{"label":"output","columns":["id","name"],"tableType":"target","colors":{"bg":"#f0fdf4","border":"#10b981","header":"#059669"}},"position":{"x":400,"y":0},"draggable":true,"sourcePosition":"right","targetPosition":"left"}],"edges":[{"id":"e_customers.id_to_output.id","source":"customers","target":"output","sourceHandle":"id","targetHandle":"id","animated":false,"style":{"stroke":"#64748b","strokeWidth":2},"data":{"expression":"id","transformation":"identity"}},{"id":"e_customers.name_to_output.name","source":"customers","target":"output","sourceHandle":"name","targetHandle":"name","animated":false,"style":{"stroke":"#64748b","strokeWidth":2},"data":{"expression":"name","transformation":"identity"}}],"options":{"minimap":false,"legend":true,"theme":"light","exportButton":true}},"evals":[],"jsHooks":[]}
```
