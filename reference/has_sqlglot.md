# Is the Python sqlglot dependency available?

dplyneage declares its sqlglot dependency via
[`reticulate::py_require()`](https://rstudio.github.io/reticulate/reference/py_require.html),
so it is provisioned automatically the first time lineage extraction
runs — you should not need to install anything. Use this to check
availability, or to gate code that calls
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
(examples, vignette chunks, Shiny apps). Note that calling it may
initialize Python.

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
