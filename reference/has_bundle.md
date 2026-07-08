# Is the React Flow bundle available?

The JavaScript bundle that powers
[`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md)
ships pre-built with the package, so this normally returns `TRUE`. If it
returns `FALSE`, diagrams fall back to a static SVG rendering; see
[`vignette("building-reactflow")`](https://tgerke.github.io/dplyneage/articles/building-reactflow.md)
for how to rebuild the bundle from source.

## Usage

``` r
has_bundle()
```

## Value

`TRUE` if the pre-built React Flow bundle is present

## Examples

``` r
has_bundle()
#> [1] TRUE
```
