# 0007. The README tracks the development version, with a temporary CRAN note

Date: 2026-09-18. Status: accepted.

## Context

CRAN accepted 0.3.1 on 2026-09-16. That release was cut from the `cran-0.3.0` branch, which left main at `a17e9ae` on 2026-08-25 and carries two commits past that point. Main kept moving. The dtplyr, duckplyr, and arrow engines, column labels, `lineage_check()`, `lineage_unused()`, `lineage_emit()`, `lineage_from_json()`, and the `lineage_flow()` theme, legend, and minimap arguments all landed after the branch point and ship with 0.4.0.

`README.Rmd` on main documents all of that, and its Installation section leads with `install.packages("dplyneage")`. The pkgdown site builds from main with no development mode, so its home page says the same thing. Someone who installs from CRAN and follows the README meets missing functions and unknown arguments on their first try. CRAN's own package page is unaffected, since it shows the README from the 0.3.1 tarball.

## Decision

The README keeps tracking the development version. A short note under Installation in `README.Rmd` says so, names the headline features that need the GitHub install, and links the changelog. An HTML comment above the note marks it for removal once 0.4.0 is on CRAN.

## Alternatives considered

Turning on pkgdown's `development: mode: auto` would keep release docs at the site root and move development docs to `/dev/`. The site has never had a release build, so this means building one from the `v0.3.1` tag. It would also break links: four of the five articles the README points to (`lineage-ci`, `openlineage`, `targets-lineage`, `ducklake-versioned-lineage`) exist only on main, and the README links them at root URLs. That is a larger change than a temporary mismatch justifies.

Leaving the README alone was the other option. The mismatch goes away at 0.4.0, but until then it greets CRAN installers with errors, and the note costs two sentences.

## How it was decided and checked

An LLM coding assistant (Claude Code) found the gap during a README review the maintainer asked for and proposed the note. The maintainer approved it.

The gap was measured from git. `git show v0.3.1:NAMESPACE` against main's `NAMESPACE` shows five exports added since the tag. The `extract_lineage()` and `lineage_flow()` signatures at the tag lack `labels`, `theme`, `legend`, and `minimap`, and the tag has no dtplyr, duckplyr, or arrow engine files.

The same review asked whether the README's account of when Python is needed was still right. It was, while `vignettes/python-integration.Rmd` still described two engines and never mentioned duckplyr. Because the docs disagreed with each other, the claims were checked against the dispatch code: `extract_lineage_data()` in `R/sqlglot_utils.R` and the engine registry in `R/lineage_engines.R`.

## Revisit if

0.4.0 reaches CRAN: delete the note. If main routinely runs far ahead of CRAN after that, reconsider pkgdown's development mode.
