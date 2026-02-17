#' Create a Column Lineage Flow Diagram
#'
#' @param nodes A list of nodes
#' @param edges A list of edges
#' @param width Width of the widget
#' @param height Height of the widget
#' @param elementId Element ID
#' @return An htmlwidget object
#' @export
lineage_flow <- function(nodes = list(), edges = list(), width = NULL, height = NULL, elementId = NULL) {
  x <- list(nodes = nodes, edges = edges)
  
  htmlwidgets::createWidget(
    name = 'lineage_flow',
    x,
    width = width,
    height = height,
    package = 'dplyneage',
    elementId = elementId
  )
}

#' @export
lineage_flowOutput <- function(outputId, width = '100%', height = '400px'){
  htmlwidgets::shinyWidgetOutput(outputId, 'lineage_flow', width, height, package = 'dplyneage')
}

#' @export
renderLineageFlow <- function(expr, env = parent.frame(), quoted = FALSE) {
  if (!quoted) { expr <- substitute(expr) }
  htmlwidgets::shinyRenderWidget(expr, lineage_flowOutput, env, quoted = TRUE)
}
