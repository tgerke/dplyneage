# Shiny bindings for lineage_flow

Output and render functions for using lineage_flow within Shiny
applications and interactive Rmd documents.

## Usage

``` r
lineage_flowOutput(outputId, width = "100%", height = "400px")

renderLineageFlow(expr, env = parent.frame(), quoted = FALSE)
```

## Arguments

- outputId:

  output variable to read from

- width, height:

  Must be a valid CSS unit (like `'100%'`, `'400px'`, `'auto'`) or a
  number, which will be coerced to a string and have `'px'` appended.

- expr:

  An expression that generates a lineage_flow

- env:

  The environment in which to evaluate `expr`.

- quoted:

  Is `expr` a quoted expression (with
  [`quote()`](https://rdrr.io/r/base/substitute.html))? This is useful
  if you want to save an expression in a variable.

## Examples

``` r
if (interactive() && requireNamespace("shiny", quietly = TRUE)) {
  library(shiny)

  ui <- fluidPage(
    lineage_flowOutput("lineage", height = "600px")
  )
  server <- function(input, output, session) {
    output$lineage <- renderLineageFlow(lineage_example())
  }
  shinyApp(ui, server)
}
```
