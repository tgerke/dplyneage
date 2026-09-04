# Lineage that travels with the data

A [ducklake](https://github.com/tgerke/ducklake-r) snapshot records what
a table’s rows were at a point in time. It records nothing about how
those rows were derived. That lives in code, in a git history the person
reading the lake may not have, and the usual bridge is a git SHA in the
commit message, which turns “how was this dataset built?” into “check
out that commit and read it”.

The two packages close the gap with no new mechanism on either side. A
layer’s column lineage is a small JSON document,
[`lineage_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md).
A ducklake commit accepts a free-text `commit_extra_info` field. Put the
one in the other and the commit that materialized a table carries the
derivation that produced it: `get_ducklake_table_version("adsl", v)`
returns the rows as of snapshot `v`, and
[`lineage_from_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md)
of the same snapshot returns the lineage, from the same catalog.

## When to do this

Someone has the lake and not the repository. A statistician checking a
table, or an auditor reading a data cut, can ask where `adsl.TRT01A`
came from without checking anything out, installing the pipeline, or
opening a connection to anything but the lake.

A data cut and a code change look the same in the snapshot list. Both
add a snapshot with a message. Lineage on the commit tells them apart:
identical lineage means the rows moved and the derivation did not, and a
changed lineage means the derivation moved, with
[`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md)
naming the columns.

The derivation is part of the record. For a regulated dataset, how
`adsl` was built as of a cut is something a reviewer can ask about years
later. Storing it on the commit versions it with the data, so snapshot
retention applies to both together and the answer never depends on
someone keeping the right commit of the right repository.

Two things this does not do. It records structure, not values: which
rows changed between snapshots is ducklake’s
[`get_table_changes()`](https://tgerke.github.io/ducklake-r/reference/get_table_changes.html),
while lineage says which columns fed which. And it records what was
written rather than gating it.
[`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md)
on a pull request stops a breaking change before it lands (the [lineage
checks in
CI](https://tgerke.github.io/dplyneage/articles/lineage-ci.html)
article); lineage on the commit documents the change after it did. A
table written without the helper below carries no lineage, so the
convention has to hold wherever the lake is written.

## Where lineage can live

The document
[`lineage_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md)
writes has three homes, and each answers to a different reader.

| Where it lives | Who reads it | Article |
|----|----|----|
| The repository, as a committed file | [`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md) on a pull request, before merge | [Lineage checks in CI](https://tgerke.github.io/dplyneage/articles/lineage-ci.html) |
| A catalog, as OpenLineage events | Marquez, DataHub, or any OpenLineage backend, beside dbt and Airflow lineage | [OpenLineage export and catalog round-trips](https://tgerke.github.io/dplyneage/articles/openlineage.html) |
| The lake, on the commit | Anyone with the lake, as of any snapshot | This article |

It is the same document each time, so a project can do all three from
one extraction. The rest of this article is the third row.

## A lake and a publish helper

The lake lives in a temporary directory, and the article attaches it
once. The data is two SDTM domains from
[pharmaversesdtm](https://pharmaverse.github.io/pharmaversesdtm/):
demographics and exposure.

``` r

library(dplyneage)
library(ducklake)
library(dplyr)

install_ducklake()

lake_dir <- file.path(tempdir(), "versioned_lake")
dir.create(lake_dir, showWarnings = FALSE)
attach_ducklake("versioned_lake", lake_path = lake_dir)
```

`publish()` materializes a layer and records its lineage on the same
commit. It returns the snapshot id that commit produced.

``` r

publish <- function(recipe, name, message) {
  lineage <- if (inherits(recipe, "tbl_lazy")) {
    lineage_json(extract_lineage(setNames(list(recipe), name)), pretty = FALSE)
  }
  with_transaction(
    replace_table(recipe, name),
    author = "pipeline",
    commit_message = message,
    commit_extra_info = lineage
  )
  invisible(max(list_table_snapshots()$snapshot_id))
}
```

Two choices in the helper matter. `pretty = FALSE` writes the document
as a single line, which is the shape a metadata column wants. And the
recipe reaches
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
as a one-element named list rather than on its own, so the output node
takes the table’s name: the stored lineage says `adsl.TRT01A` rather
than `output.TRT01A`, and documents from several tables can be stitched
together later.

Bronze layers are data frames, and a data frame has no query tree to
read, so they carry no lineage; their commit message says where they
came from. Demographics are complete from the first extract. Exposure
records accrue as subjects are dosed, so that domain takes a cut date.

``` r

publish(pharmaversesdtm::dm, "dm", "Bronze: demographics")

ex_cut <- filter(pharmaversesdtm::ex, EXSTDTC <= "2013-12-31")
publish(ex_cut, "ex", "Bronze: exposure through 2013-12-31")
```

## The first cut

The gold layer keeps a few demographic columns, joins the first dose
date from exposure, and derives planned and actual treatment, an age
group, and a safety flag. The derivations are written as dplyr so the
hop stays a query. admiral’s versions work on data frames and leave no
query tree behind; ducklake-r’s [Clinical Trial Data
Lake](https://tgerke.github.io/ducklake-r/articles/clinical-trial-datalake.html)
article shows that side of the workflow.

``` r

build_adsl <- function() {
  first_dose <- get_ducklake_table("ex") |>
    filter(!is.na(EXSTDTC)) |>
    group_by(USUBJID) |>
    summarise(TRTSDT = min(EXSTDTC, na.rm = TRUE), .groups = "drop")

  get_ducklake_table("dm") |>
    select(USUBJID, AGE, SEX, ARM, ACTARM) |>
    left_join(first_dose, by = "USUBJID") |>
    mutate(
      TRT01P = ARM,
      TRT01A = ACTARM,
      AGEGR1 = case_when(AGE < 65 ~ "<65", AGE < 80 ~ "65-79", TRUE ~ ">=80"),
      SAFFL = if_else(is.na(TRTSDT), "N", "Y")
    )
}
```

``` r

v1 <- publish(build_adsl(), "adsl", "Gold: ADSL, first cut")
```

The snapshot list shows the lineage riding along. Nothing here prints
the document itself;
[`lineage_from_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md)
is the way to read it.

``` r

list_table_snapshots("adsl") |>
  transmute(snapshot_id, commit_message, lineage_chars = nchar(commit_extra_info))
#>   snapshot_id        commit_message lineage_chars
#> 1           3 Gold: ADSL, first cut          2839
```

## Reading it back

`lineage_at()` finds the snapshot and hands its document to
[`lineage_from_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md).
The check matters in a real lake: a snapshot written by anything other
than `publish()` has no document, and the helper should say so rather
than fail inside the parser.

``` r

lineage_at <- function(table, version) {
  snapshots <- list_table_snapshots(table)
  doc <- snapshots$commit_extra_info[snapshots$snapshot_id == version]
  if (length(doc) != 1 || is.na(doc)) {
    stop("Snapshot ", version, " of ", table, " carries no lineage.")
  }
  lineage_from_json(doc)
}
```

No extraction ran to draw this diagram. It came from the catalog:

``` r

lineage_flow(lineage_at("adsl", v1), height = "400px")
```

And this is the pairing the whole arrangement exists for: the rows and
the derivation, both keyed by one snapshot id.

``` r

get_ducklake_table_version("adsl", v1) |>
  count(SAFFL) |>
  collect()
#> # A tibble: 2 × 2
#>   SAFFL     n
#>   <chr> <dbl>
#> 1 N        94
#> 2 Y       212

lineage_upstream(lineage_at("adsl", v1), "adsl.SAFFL")
#> [1] "ex.EXSTDTC"
```

What comes back is the same object
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
would have returned, so everything that accepts a lineage accepts it:
[`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md)
for the diagram,
[`lineage_upstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)
and
[`lineage_downstream()`](https://tgerke.github.io/dplyneage/reference/lineage_upstream.md)
for impact questions,
[`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md)
and
[`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md)
between two snapshots, and
[`lineage_openlineage()`](https://tgerke.github.io/dplyneage/reference/lineage_openlineage.md)
to send one snapshot’s lineage on to a catalog.

[`get_ducklake_table_version()`](https://tgerke.github.io/ducklake-r/reference/get_ducklake_table_version.html)
builds its query from raw SQL. Tracing that query would send
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
to the sqlglot engine, as the [ducklake
lineage](https://tgerke.github.io/dplyneage/articles/ducklake-lineage.html)
article shows, but here it only fetches rows. The lineage was extracted
from the recipe on the R engine when the layer was published, so this
article runs without Python.

## A data refresh

Six months on, more subjects have been dosed. The exposure cut moves and
the gold layer is rebuilt from the same recipe.

``` r

ex_cut <- filter(pharmaversesdtm::ex, EXSTDTC <= "2014-06-30")
publish(ex_cut, "ex", "Bronze: exposure through 2014-06-30")

v2 <- publish(build_adsl(), "adsl", "Gold: ADSL, second cut")
```

The safety flag moved with the data:

``` r

get_ducklake_table_version("adsl", v2) |>
  count(SAFFL) |>
  collect()
#> # A tibble: 2 × 2
#>   SAFFL     n
#>   <chr> <dbl>
#> 1 N        54
#> 2 Y       252
```

The lineage did not:

``` r

lineage_diff(lineage_at("adsl", v1), lineage_at("adsl", v2))
#> No lineage changes.
```

The snapshot list shows two commits with two messages. The lineage is
what says the second one changed rows and nothing else.

## A refactor

Someone tidying `build_adsl()` points actual treatment at the planned
arm. The pipeline still runs, the table is republished, and the twelve
subjects whose actual arm differs from their randomized arm get a
different `TRT01A`.

``` r

build_adsl <- function() {
  first_dose <- get_ducklake_table("ex") |>
    filter(!is.na(EXSTDTC)) |>
    group_by(USUBJID) |>
    summarise(TRTSDT = min(EXSTDTC, na.rm = TRUE), .groups = "drop")

  get_ducklake_table("dm") |>
    select(USUBJID, AGE, SEX, ARM, ACTARM) |>
    left_join(first_dose, by = "USUBJID") |>
    mutate(
      TRT01P = ARM,
      TRT01A = ARM,
      AGEGR1 = case_when(AGE < 65 ~ "<65", AGE < 80 ~ "65-79", TRUE ~ ">=80"),
      SAFFL = if_else(is.na(TRTSDT), "N", "Y")
    )
}

v3 <- publish(build_adsl(), "adsl", "Gold: ADSL, tidied derivations")
```

This time the diff is not empty:

``` r

lineage_diff(lineage_at("adsl", v2), lineage_at("adsl", v3))
#> <dplyneage lineage diff>
#> Added edges:
#>   + dm.ARM -> adsl.TRT01A
#> Removed edges:
#>   - dm.ACTARM -> adsl.TRT01A [breaking]
```

The removed edge is breaking because `adsl` is the table the lake’s
consumers read, and `TRT01A` is one of the columns they read from it.
[`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md)
is the same comparison raised as an error. In CI it is a gate; on the
lake it is a question asked after the fact, and the question “which
commit changed the derivation?” has an answer from the catalog alone:

``` r

derivation_history <- function(table) {
  snapshots <- list_table_snapshots(table)
  lineages <- lapply(snapshots$commit_extra_info, lineage_from_json)
  changed <- vapply(seq_along(lineages)[-1], function(i) {
    lineage_has_changes(lineage_diff(lineages[[i - 1]], lineages[[i]]))
  }, logical(1))
  data.frame(
    snapshot_id = snapshots$snapshot_id,
    commit_message = snapshots$commit_message,
    lineage_changed = c(NA, changed)
  )
}

derivation_history("adsl")
#>   snapshot_id                 commit_message lineage_changed
#> 1           3          Gold: ADSL, first cut              NA
#> 2           5         Gold: ADSL, second cut           FALSE
#> 3           6 Gold: ADSL, tidied derivations            TRUE
```

Three snapshots, one derivation change, and
[`list_table_snapshots()`](https://tgerke.github.io/ducklake-r/reference/list_table_snapshots.html)
on its own could not have said which.

## Before adopting it

The document here is a few kilobytes, and DuckLake stores
`commit_extra_info` as unbounded text, so size is not a constraint at
this scale. If a lake’s conventions keep commit metadata short, or
lineage is wanted for tables that something other than the pipeline
writes, a versioned `lineage` table keyed by table name and snapshot id
holds the same document; ducklake-r’s clinical trial article stores
define.xml that way.
[`lineage_from_json()`](https://tgerke.github.io/dplyneage/reference/lineage_json.md)
reads it back from either place.

Snapshot expiry removes the lineage with the snapshot. That is the same
lifecycle as the data, which is the point: the derivation stays
available for exactly as long as the rows it describes.

A
[targets](https://tgerke.github.io/dplyneage/articles/targets-lineage.html)
pipeline gets this with a one-line change. That article’s `publish()` is
this one without the `commit_extra_info` argument. Add it and every
layer’s commit carries its lineage, while `project_lineage()` there
keeps reading the store as before.

## Next steps

- The [ducklake
  lineage](https://tgerke.github.io/dplyneage/articles/ducklake-lineage.html)
  article covers per-hop diagrams, stitching a whole lake, and lineage
  from time-travel queries
- The
  [targets](https://tgerke.github.io/dplyneage/articles/targets-lineage.html)
  article runs a bronze/silver/gold lake as a pipeline and separates
  data refreshes from provenance changes with `tar_outdated()` beside
  [`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md)
- The [lineage checks in
  CI](https://tgerke.github.io/dplyneage/articles/lineage-ci.html)
  article fails the pull request that would introduce a breaking change
- The
  [OpenLineage](https://tgerke.github.io/dplyneage/articles/openlineage.html)
  article sends the same document into a catalog
- ducklake’s [time
  travel](https://tgerke.github.io/ducklake-r/articles/time-travel.html)
  and
  [transactions](https://tgerke.github.io/ducklake-r/articles/transactions.html)
  vignettes cover the lake side
- Found a snapshot whose lineage reads back wrong? Please [open an
  issue](https://github.com/tgerke/dplyneage/issues)
