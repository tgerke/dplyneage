# Project-level lineage for targets pipelines

dbt and SQLMesh compute lineage for a whole project. dplyneage works on
what you hand it in a session: one query, or a named list of them. In R
the project is a [targets](https://docs.ropensci.org/targets/) pipeline,
and targets already knows the half of the story dplyneage doesn’t: which
targets are out of date and what a change will rerun. Its graph stops at
the target, though. It can say that `adae` depends on `adsl`. It can’t
say which column of `adsl` feeds `TRTEMFL`.

The two compose without a new API. A target’s value can carry the lazy
query that built it,
[`tar_read()`](https://docs.ropensci.org/targets/reference/tar_read.html)
hands that query back with no database attached, and
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
on a named list of those queries stitches the project into one diagram.

This article builds a small clinical-trial lake as a targets pipeline
(three SDTM domains from
[pharmaversesdtm](https://pharmaverse.github.io/pharmaversesdtm/),
materialized as bronze, silver, and gold layers with
[ducklake](https://github.com/tgerke/ducklake-r)) and runs it three
times: an interim data cut, a later cut where only adverse events have
accrued, and a code change. targets reports what reran. dplyneage
reports whether the provenance moved. Those turn out to be different
questions.

## A lake and a pipeline

The lake lives in the project directory, and the article attaches it
once.

``` r

library(dplyneage)
library(targets)
library(ducklake)
library(dplyr)

install_ducklake()

lake_dir <- file.path(proj_dir, "lake")
dir.create(lake_dir)
attach_ducklake("trial_lake", lake_path = lake_dir)
```

Each target builds one layer of the lake and returns a small handle
rather than the table itself:

- `table` is the name the layer was materialized under. Downstream
  targets read the lake by this name.
- `snapshot` is ducklake’s commit id for that write. When new data
  lands, the id changes, targets sees a changed value, and everything
  downstream reruns.
- `recipe` is the lazy dplyr query that built the layer. Bronze layers
  are loaded from data frames and have none. Silver and gold layers do,
  and the recipe is what dplyneage reads.

The handle keeps the targets graph honest. `build_adae(ae, adsl)` names
the two targets it depends on, reads their tables by name, and never
composes on the upstream query, so each layer’s lineage is one hop: the
tables it read and the columns it made from them.

``` r

publish <- function(recipe, name, message) {
  with_transaction(
    replace_table(recipe, name),
    author = "targets",
    commit_message = message
  )
  handle <- list(
    table = name,
    snapshot = max(list_table_snapshots()$snapshot_id)
  )
  if (inherits(recipe, "tbl_lazy")) {
    handle$recipe <- recipe
  }
  handle
}

read_layer <- function(handle) {
  get_ducklake_table(handle$table)
}

load_bronze <- function(data, name) {
  publish(data, name, paste("Bronze:", name))
}

clean_dm <- function(raw) {
  read_layer(raw) |>
    select(USUBJID, AGE, SEX, RACE, ARM, ACTARM) |>
    filter(ARM != "Screen Failure") |>
    mutate(across(c(SEX, RACE, ARM, ACTARM), ~ na_if(.x, ""))) |>
    publish("dm", "Silver: demographics")
}

clean_ex <- function(raw) {
  read_layer(raw) |>
    select(USUBJID, EXDOSE, EXSTDTC, EXENDTC) |>
    mutate(across(c(EXSTDTC, EXENDTC), ~ na_if(.x, ""))) |>
    publish("ex", "Silver: exposure")
}

clean_ae <- function(raw) {
  read_layer(raw) |>
    select(USUBJID, AESEQ, AEDECOD, AESEV, AESER, AESTDTC) |>
    mutate(across(c(AEDECOD, AESEV, AESTDTC), ~ na_if(.x, ""))) |>
    publish("ae", "Silver: adverse events")
}

build_adsl <- function(dm, ex) {
  first_dose <- read_layer(ex) |>
    filter(!is.na(EXSTDTC)) |>
    group_by(USUBJID) |>
    summarise(TRTSDT = min(EXSTDTC, na.rm = TRUE), .groups = "drop")

  read_layer(dm) |>
    left_join(first_dose, by = "USUBJID") |>
    mutate(
      TRT01P = ARM,
      TRT01A = ACTARM,
      AGEGR1 = case_when(AGE < 65 ~ "<65", AGE < 80 ~ "65-79", TRUE ~ ">=80"),
      SAFFL = if_else(is.na(TRTSDT), "N", "Y")
    ) |>
    publish("adsl", "Gold: subject-level analysis dataset")
}

build_adae <- function(ae, adsl) {
  read_layer(ae) |>
    inner_join(
      read_layer(adsl) |> select(USUBJID, TRT01A, TRTSDT, SAFFL),
      by = "USUBJID"
    ) |>
    mutate(TRTEMFL = if_else(AESTDTC >= TRTSDT, "Y", "N")) |>
    publish("adae", "Gold: adverse-event analysis dataset")
}
```

The silver step does the blank-to-`NA` cleaning that admiral’s
`convert_blanks_to_na()` would do, written as dplyr so the hop stays a
query. The gold derivations are deliberately plain: `ADSL` gets planned
and actual treatment, an age group, first dose date, and a safety flag;
`ADAE` joins the treatment start onto each event and flags the
treatment-emergent ones. Real derivations go through admiral, whose
functions work on data frames and so leave no query tree behind;
ducklake-r’s [Clinical Trial Data
Lake](https://tgerke.github.io/ducklake-r/articles/clinical-trial-datalake.html)
article shows that side of the workflow.

## The interim cut

Demographics and exposure are locked from the first extract. Adverse
events keep accruing through follow-up, so the pipeline takes a cut date
for that domain and nothing else. The date is an ordinary R object that
the `ae_raw` command refers to, and targets hashes it like any other
global.

``` r

ae_cut_date <- "2013-12-31"

tar_script({
  tar_option_set(packages = c("dplyr", "ducklake"))
  list(
    tar_target(dm_raw, load_bronze(pharmaversesdtm::dm, "dm_raw")),
    tar_target(ex_raw, load_bronze(pharmaversesdtm::ex, "ex_raw")),
    tar_target(
      ae_raw,
      load_bronze(filter(pharmaversesdtm::ae, AESTDTC <= ae_cut_date), "ae_raw")
    ),
    tar_target(dm, clean_dm(dm_raw)),
    tar_target(ex, clean_ex(ex_raw)),
    tar_target(ae, clean_ae(ae_raw)),
    tar_target(adsl, build_adsl(dm, ex)),
    tar_target(adae, build_adae(ae, adsl))
  )
}, ask = FALSE)

tar_outdated(callr_function = NULL, reporter = "silent")
#> [1] "ae"     "adae"   "dm_raw" "adsl"   "ex_raw" "ex"     "ae_raw" "dm"
```

One choice needs explaining. targets normally runs `_targets.R` in a
fresh process, which is what makes a pipeline reproducible. This article
runs it in the current session instead (`callr_function = NULL`), for
two reasons: the layer functions above are defined here rather than in
an `R/` directory, and a ducklake catalog is a single DuckDB file that
two processes cannot both hold open for writing. The last section covers
what changes in a real project.

``` r

tar_make(callr_function = NULL, reporter = "silent")
tar_progress()
#> # A tibble: 8 × 2
#>   name   progress 
#>   <chr>  <chr>    
#> 1 ae_raw completed
#> 2 dm_raw completed
#> 3 ex_raw completed
#> 4 ae     completed
#> 5 dm     completed
#> 6 ex     completed
#> 7 adsl   completed
#> 8 adae   completed
```

## What a target holds

Bronze handles carry a name and a snapshot. Gold handles carry the query
too.

``` r

str(tar_read(dm_raw))
#> List of 2
#>  $ table   : chr "dm_raw"
#>  $ snapshot: num 2

names(tar_read(adsl))
#> [1] "table"    "snapshot" "recipe"
```

The recipe came back from the store, and its connection did not.
[`tar_make()`](https://docs.ropensci.org/targets/reference/tar_make.html)
saved it with [`saveRDS()`](https://rdrr.io/r/base/readRDS.html), and a
DuckDB connection does not survive that round trip, so printing the
recipe would fail when dplyr tried to run a preview.
[`show_query()`](https://dplyr.tidyverse.org/reference/explain.html) and
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
only read the query tree, which is why lineage from a store needs no
database at all.

``` r

adsl_recipe <- tar_read(adsl)$recipe

show_query(adsl_recipe)
#> <SQL>
#> SELECT
#>   *,
#>   ARM AS TRT01P,
#>   ACTARM AS TRT01A,
#>   CASE WHEN (AGE < 65.0) THEN '<65' WHEN (AGE < 80.0) THEN '65-79' ELSE '>=80' END AS AGEGR1,
#>   CASE WHEN ((TRTSDT IS NULL)) THEN 'N' WHEN NOT ((TRTSDT IS NULL)) THEN 'Y' END AS SAFFL
#> FROM (
#>   SELECT dm.*, TRTSDT
#>   FROM dm
#>   LEFT JOIN (
#>     SELECT USUBJID, MIN(EXSTDTC) AS TRTSDT
#>     FROM ex
#>     WHERE (NOT((EXSTDTC IS NULL)))
#>     GROUP BY USUBJID
#>   ) AS RHS
#>     ON (dm.USUBJID = RHS.USUBJID)
#> ) AS q01
```

On its own, a recipe diagrams a single hop, the same as any lazy table:

``` r

adsl_recipe |>
  extract_lineage() |>
  lineage_flow(height = "400px")
```

## The whole project in one diagram

The project graph is the recipes of every completed target, named by the
table each one materialized, passed to
[`extract_lineage()`](https://tgerke.github.io/dplyneage/reference/extract_lineage.md)
as a list. That naming is what stitches the hops together: `adae` reads
a table called `adsl`, and a model in the list is called `adsl`, so the
two connect.

``` r

project_lineage <- function() {
  handles <- lapply(sort(tar_meta(targets_only = TRUE)$name), tar_read_raw)
  handles <- Filter(function(h) !is.null(h$recipe), handles)
  recipes <- lapply(handles, function(h) h$recipe)
  names(recipes) <- vapply(handles, function(h) h$table, character(1))
  extract_lineage(recipes)
}

interim <- project_lineage()
lineage_flow(interim, height = "600px")
```

Bronze handles have no recipe and never enter the list, but the silver
recipes read their tables, so `dm_raw`, `ex_raw`, and `ae_raw` appear as
blue source nodes. `adsl` is orange because `adae` reads it. `adae` is
green because nothing does.

Impact analysis works across the hops. A treatment-emergent flag depends
on dates from two domains, three layers back:

``` r

lineage_upstream(interim, "adae.TRTEMFL")
#> [1] "adsl.TRTSDT"    "ae_raw.AESTDTC" "ae.AESTDTC"     "ex_raw.EXSTDTC"
#> [5] "ex.EXSTDTC"
```

## A later data cut

Six months on, the adverse-event extract is longer and nothing else has
changed. Moving the cut date is the only edit.

``` r

ae_cut_date <- "2014-06-30"

tar_outdated(callr_function = NULL, reporter = "silent")
#> [1] "ae"     "adae"   "ae_raw"
```

targets traced the new value to `ae_raw` and from there to the two
targets that read it. The other five are skipped:

``` r

tar_make(callr_function = NULL, reporter = "silent")
tar_progress()
#> # A tibble: 8 × 2
#>   name   progress 
#>   <chr>  <chr>    
#> 1 ae_raw completed
#> 2 dm_raw skipped  
#> 3 ex_raw skipped  
#> 4 ae     completed
#> 5 dm     skipped  
#> 6 ex     skipped  
#> 7 adsl   skipped  
#> 8 adae   completed
```

The lake now has a second snapshot of `ae_raw`, `ae`, and `adae`. The
lineage is the same graph it was, because rows changed and columns did
not:

``` r

refreshed <- project_lineage()
lineage_has_changes(lineage_diff(interim, refreshed))
#> [1] FALSE
```

[`tar_outdated()`](https://docs.ropensci.org/targets/reference/tar_outdated.html)
and
[`lineage_diff()`](https://tgerke.github.io/dplyneage/reference/lineage_diff.md)
look at the same run and answer different questions. One says the data
moved. The other says the structure didn’t. For a study database that
gets a new cut every few weeks, that second answer is the one a reviewer
wants to see, and it costs nothing to produce.

## A code change

Now a refactor. Someone tidying `build_adsl()` points actual treatment
at the planned arm, a one-word change that alters numbers for the twelve
subjects whose actual arm differs from their randomized arm. The
pipeline still runs.

``` r

build_adsl <- function(dm, ex) {
  first_dose <- read_layer(ex) |>
    filter(!is.na(EXSTDTC)) |>
    group_by(USUBJID) |>
    summarise(TRTSDT = min(EXSTDTC, na.rm = TRUE), .groups = "drop")

  read_layer(dm) |>
    left_join(first_dose, by = "USUBJID") |>
    mutate(
      TRT01P = ARM,
      TRT01A = ARM,
      AGEGR1 = case_when(AGE < 65 ~ "<65", AGE < 80 ~ "65-79", TRUE ~ ">=80"),
      SAFFL = if_else(is.na(TRTSDT), "N", "Y")
    ) |>
    publish("adsl", "Gold: subject-level analysis dataset")
}

tar_outdated(callr_function = NULL, reporter = "silent")
#> [1] "adae" "adsl"
```

targets hashes functions as well as objects, so the edit invalidates
`adsl` and, through it, `adae`. The bronze and silver layers stay put:

``` r

tar_make(callr_function = NULL, reporter = "silent")
tar_progress()
#> # A tibble: 8 × 2
#>   name   progress 
#>   <chr>  <chr>    
#> 1 ae_raw skipped  
#> 2 dm_raw skipped  
#> 3 ex_raw skipped  
#> 4 ae     skipped  
#> 5 dm     skipped  
#> 6 ex     skipped  
#> 7 adsl   completed
#> 8 adae   completed
```

This time the diff is not empty:

``` r

refactored <- project_lineage()
lineage_diff(refreshed, refactored)
#> <dplyneage lineage diff>
#> Added edges:
#>   + dm.ARM -> adsl.TRT01A
#> Removed edges:
#>   - dm.ACTARM -> adsl.TRT01A [breaking]
```

The removed edge is breaking because `adsl.TRT01A` feeds `adae.TRT01A`,
and a column that something downstream consumes has changed its source.
[`lineage_check()`](https://tgerke.github.io/dplyneage/reference/lineage_check.md)
turns that into an error:

``` r

lineage_check(refreshed, refactored, annotate = FALSE)
#>   non-breaking: added edge dm.ARM -> adsl.TRT01A
#>   breaking: removed edge dm.ACTARM -> adsl.TRT01A
#> Error:
#> ! Lineage check failed: 1 breaking lineage change (2 total). Inspect with lineage_diff(old, new); fail_on = "none" reports without failing.
```

We pass `annotate = FALSE` because this article renders on a GitHub
Actions runner, where the default prints workflow commands instead of
plain lines. In a pull request that failure is the point: the [lineage
checks in
CI](https://tgerke.github.io/dplyneage/articles/lineage-ci.html) article
has the job that runs it.

## Taking this to a real project

Three things move when this leaves the article. The layer functions go
into `R/` and `_targets.R` loads them with
[`tar_source()`](https://docs.ropensci.org/targets/reference/tar_source.html).
The lake is attached inside `_targets.R`, so the pipeline process is the
only one holding the catalog during a build. And
[`tar_make()`](https://docs.ropensci.org/targets/reference/tar_make.html)
runs with its default fresh process.

``` r

# _targets.R
library(targets)
tar_option_set(packages = c("dplyr", "ducklake"))
tar_source()
attach_ducklake("trial_lake", lake_path = "lake")
ae_cut_date <- "2014-06-30"

list(
  tar_target(dm_raw, load_bronze(pharmaversesdtm::dm, "dm_raw")),
  tar_target(ex_raw, load_bronze(pharmaversesdtm::ex, "ex_raw")),
  tar_target(ae_raw, load_bronze(read_ae_extract(ae_cut_date), "ae_raw")),
  tar_target(dm, clean_dm(dm_raw)),
  tar_target(ex, clean_ex(ex_raw)),
  tar_target(ae, clean_ae(ae_raw)),
  tar_target(adsl, build_adsl(dm, ex)),
  tar_target(adae, build_adae(ae, adsl))
)
```

`project_lineage()` stays as it is. It reads only the store, so it can
run after
[`tar_make()`](https://docs.ropensci.org/targets/reference/tar_make.html)
in the same CI job with the lake already closed, and its result is the
value the lineage check compares between branches.

## Next steps

- The [ducklake
  lineage](https://tgerke.github.io/dplyneage/articles/ducklake-lineage.html)
  article covers per-hop diagrams and lineage from time-travel queries
- ducklake-r’s [Clinical Trial Data
  Lake](https://tgerke.github.io/ducklake-r/articles/clinical-trial-datalake.html)
  article builds the full SDTM-to-ADaM lake, admiral derivations
  included
- The [targets manual](https://books.ropensci.org/targets/) covers
  [`tar_source()`](https://docs.ropensci.org/targets/reference/tar_source.html),
  cues, and everything else about running the pipeline
- Found a pipeline that stitches wrong? Please [open an
  issue](https://github.com/tgerke/dplyneage/issues)
