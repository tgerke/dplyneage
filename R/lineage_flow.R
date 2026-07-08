#' Render an interactive column lineage diagram
#'
#' Draws a lineage graph with [React Flow](https://reactflow.dev/): tables
#' as draggable nodes, column-to-column edges, and zoom/pan controls. Pass
#' the result of [extract_lineage()] directly (it is detected
#' automatically, so piping works), or build `nodes` and `edges` yourself
#' with [create_table_node()] and [create_column_edge()].
#'
#' @param nodes The output of [extract_lineage()], or a list of nodes
#'   created with [create_table_node()].
#' @param edges A list of edges created with [create_column_edge()].
#'   Ignored when `nodes` is an [extract_lineage()] result, which carries
#'   its own edges.
#' @param width,height CSS dimensions of the widget, e.g. `"100%"` or
#'   `"600px"`. Default to full width and 600px tall.
#' @param elementId Explicit HTML element id for the widget. Usually left
#'   `NULL` so one is generated.
#' @return An htmlwidget that prints in the RStudio viewer, R Markdown /
#'   Quarto documents, and Shiny apps.
#' @seealso [extract_lineage()] to compute lineage automatically;
#'   [lineage_flowOutput()] and [renderLineageFlow()] for Shiny.
#' @export
#' @examples
#' # Build a small diagram by hand
#' nodes <- list(
#'   create_table_node("orders", c("order_id", "amount"), x = 0, y = 0),
#'   create_table_node("daily_totals", c("total"),
#'     x = 400, y = 0, table_type = "target"
#'   )
#' )
#' edges <- list(
#'   create_column_edge("orders", "amount", "daily_totals", "total",
#'     label = "SUM()", animated = TRUE
#'   )
#' )
#' lineage_flow(nodes, edges)
#' @examplesIf dplyneage::has_sqlglot()
#' # Or pipe from extract_lineage()
#' extract_lineage("SELECT id, name FROM customers") |>
#'   lineage_flow()
lineage_flow <- function(nodes = list(), edges = list(), width = NULL, height = NULL, elementId = NULL) {
  # Detect if 'nodes' is actually the output from extract_lineage()
  # (a list with both $nodes and $edges components)
  if (is.list(nodes) && !is.null(nodes$nodes) && !is.null(nodes$edges)) {
    # Extract the nodes and edges from the lineage object
    lineage_obj <- nodes
    nodes <- lineage_obj$nodes
    edges <- lineage_obj$edges
  }
  
  # Set default dimensions if not specified (important for RStudio viewer)
  if (is.null(width)) {
    width <- "100%"
  }
  if (is.null(height)) {
    height <- "600px"
  }
  
  x <- list(nodes = nodes, edges = edges)
  
  widget <- htmlwidgets::createWidget(
    name = 'lineage_flow',
    x,
    width = width,
    height = height,
    package = 'dplyneage',
    elementId = elementId,
    sizingPolicy = htmlwidgets::sizingPolicy(
      defaultWidth = "100%",
      defaultHeight = "600px",
      viewer.defaultWidth = "100%",
      viewer.defaultHeight = "600px",
      browser.defaultWidth = "100%",
      browser.defaultHeight = "600px",
      knitr.defaultWidth = "100%",
      knitr.defaultHeight = "600px",
      padding = 0,
      viewer.padding = 0,
      browser.padding = 0,
      knitr.figure = FALSE,
      fill = TRUE
    )
  )
  
  widget
}

#' Shiny bindings for lineage_flow
#'
#' Output and render functions for using lineage_flow within Shiny
#' applications and interactive Rmd documents.
#'
#' @param outputId output variable to read from
#' @param width,height Must be a valid CSS unit (like \code{'100\%'},
#'   \code{'400px'}, \code{'auto'}) or a number, which will be coerced to a
#'   string and have \code{'px'} appended.
#' @param expr An expression that generates a lineage_flow
#' @param env The environment in which to evaluate \code{expr}.
#' @param quoted Is \code{expr} a quoted expression (with \code{quote()})? This
#'   is useful if you want to save an expression in a variable.
#'
#' @name lineage_flow-shiny
#'
#' @examples
#' if (interactive() && requireNamespace("shiny", quietly = TRUE)) {
#'   library(shiny)
#'
#'   ui <- fluidPage(
#'     lineage_flowOutput("lineage", height = "600px")
#'   )
#'   server <- function(input, output, session) {
#'     output$lineage <- renderLineageFlow(lineage_example())
#'   }
#'   shinyApp(ui, server)
#' }
#' @export
lineage_flowOutput <- function(outputId, width = '100%', height = '400px'){
  htmlwidgets::shinyWidgetOutput(outputId, 'lineage_flow', width, height, package = 'dplyneage')
}

#' @rdname lineage_flow-shiny
#' @export
renderLineageFlow <- function(expr, env = parent.frame(), quoted = FALSE) {
  if (!quoted) { expr <- substitute(expr) }
  htmlwidgets::shinyRenderWidget(expr, lineage_flowOutput, env, quoted = TRUE)
}
