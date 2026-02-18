#' Create a Column Lineage Flow Diagram
#'
#' Creates an interactive lineage visualization using React Flow.
#' Can be used with the output from extract_lineage() directly in a pipe,
#' or called with separate nodes and edges arguments.
#'
#' @param nodes A list of nodes, or the output from extract_lineage() 
#'   (a list with $nodes and $edges). When piping from extract_lineage(),
#'   this will be automatically detected.
#' @param edges A list of edges (only needed if nodes is not from extract_lineage())
#' @param width Width of the widget
#' @param height Height of the widget
#' @param elementId Element ID
#' @return An htmlwidget object
#' @export
#' @examples
#' \dontrun{
#' # Method 1: Direct pipe from extract_lineage() (recommended)
#' tbl(con, "customers") |>
#'   select(id, name) |>
#'   extract_lineage() |>
#'   lineage_flow()
#'
#' # Method 2: Manual nodes and edges
#' lineage_flow(nodes = my_nodes, edges = my_edges)
#'
#' # Method 3: Extract lineage first, then visualize
#' lineage <- extract_lineage(query)
#' lineage_flow(lineage)
#' }
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
