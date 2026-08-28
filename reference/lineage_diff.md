# Compare two lineage extractions

Reports the column-level edges and table columns that changed between
two lineage objects — typically the same pipeline before and after an
edit. Edges are keyed by their endpoints, and an edge present in both
objects still counts as changed when its transformation classification
or defining expression differs: rewriting `sum(amount)` as
`mean(amount)` changes provenance even though the same columns stay
connected.

## Usage

``` r
lineage_diff(old, new)

lineage_has_changes(diff)
```

## Arguments

- old, new:

  Lineage objects from
  [`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
  (or lists with `nodes` and `edges`), in before/after order.

- diff:

  The result of `lineage_diff()`.

## Value

A `dplyneage_lineage_diff` list with data frame elements `added_edges`,
`removed_edges`, `changed_edges`, `added_columns`, and
`removed_columns`, each carrying a `severity` column (`"breaking"` or
`"non-breaking"`). `changed_edges` also records the old and new
transformation and expression for each edge whose endpoints matched but
whose definition differs. The print method summarises the changes;
zero-row elements mean no change. `lineage_has_changes()` returns `TRUE`
when any element has rows.

## Details

Each change is also classified by blast radius: a `severity` column on
every element marks it `"breaking"` when it could invalidate something
built on the old lineage, `"non-breaking"` otherwise. See Details for
the rule.

[`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md)
wraps the diff for CI: it prints each change and errors when the changes
cross a severity threshold.

Severity is judged against `old`, the lineage existing consumers were
built on. A removed or changed edge — and a removed column — is
`"breaking"` when its target column fed other columns downstream, or
belonged to a target node: target columns are the pipeline's consumed
surface, and the graph cannot see the dashboards and jobs reading them,
so changing one is assumed to break something. Nodes without a declared
type get the same cautious treatment. Everything else is
`"non-breaking"`: additions cannot invalidate an existing consumer, and
neither can removing an intermediate column nothing consumed.

One caveat for hand-built lineages whose edges carry no expressions:
there, adding a source to an existing column shows up only in
`added_edges`, which is always non-breaking. Engine-extracted lineage
also reports the column's surviving edges in `changed_edges`, because
its defining expression changed, and those get the breaking check.

## See also

Other lineage accessors:
[`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md),
[`lineage_edges()`](https://tgerke.github.io/dplyneage/reference/lineage_edges.md),
[`lineage_tables()`](https://tgerke.github.io/dplyneage/reference/lineage_tables.md),
[`lineage_unused()`](https://tgerke.github.io/dplyneage/reference/lineage_unused.md),
[`lineage_upstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)

## Examples

``` r
old <- list(
  nodes = list(
    create_table_node("orders", "amount"),
    create_table_node("out", "total", table_type = "target")
  ),
  edges = list(create_column_edge("orders", "amount", "out", "total"))
)
new <- list(
  nodes = list(
    create_table_node("orders", c("amount", "tax")),
    create_table_node("out", "total", table_type = "target")
  ),
  edges = list(
    create_column_edge("orders", "amount", "out", "total"),
    create_column_edge("orders", "tax", "out", "total")
  )
)
lineage_diff(old, new)
#> <dplyneage lineage diff>
#> Added edges:
#>   + orders.tax -> out.total
#> Added columns:
#>   + orders.tax
```
