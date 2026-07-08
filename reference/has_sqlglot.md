# Is the Python sqlglot dependency available?

Python is only involved when
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
analyzes raw SQL strings (or falls back to sqlglot for a pipeline it
cannot trace in R); dbplyr pipelines are analyzed by a pure-R engine.
dplyneage declares its sqlglot dependency via
[`reticulate::py_require()`](https://rstudio.github.io/reticulate/reference/py_require.html),
so it is provisioned automatically the first time it is needed — you
should not need to install anything. Use this to check availability, or
to gate code that extracts lineage from raw SQL (examples, vignette
chunks, Shiny apps). Note that calling it may initialize Python.

## Usage

``` r
has_sqlglot()
```

## Value

`TRUE` if sqlglot can be loaded, `FALSE` otherwise

## See also

[`vignette("python-integration")`](https://tgerke.github.io/dplyneage/articles/python-integration.md)
for using your own Python environment

## Examples

``` r
if (FALSE) { # \dontrun{
has_sqlglot()
} # }
```
