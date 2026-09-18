# 0004. Generate CI configuration instead of recalling it

Date: 2026-09-17. Status: accepted.

## Context

The coverage work was planned and written with an LLM coding assistant (Claude Code), with the maintainer approving each plan before implementation. Action versions, action inputs, and command-line flags are the details such a tool most often gets wrong, because they change after its training data ends and a stale answer still looks plausible.

## Decision

Where a canonical generator or reference exists, it is used and the assistant's recall is not:

- `usethis::use_github_action("test-coverage")` generated the workflow. Only the project-specific steps were written by hand.
- For actions outside the template, the latest major comes from `gh api repos/<owner>/<action>/releases/latest`, and inputs are checked against the action's own `action.yml`.
- Command-line flags are checked against `--help` on the version that will run.
- Any API the assistant knows only from recall goes through a small spike before other work depends on it.

## How it was decided and checked

The assistant raised the risk in its first plan, and the record since then bears it out.

Recalled versions were stale. The assistant planned `codecov/codecov-action@v5` and `actions/checkout@v4`. The generated template used the Codecov action at v7, pinned to a commit SHA, and `checkout@v6`. `actions/setup-node` was at v7.

Local validation runs caught three wrong expectations before anything was pushed: the `relative_files` behavior described in 0002; that `Page.addScriptToEvaluateOnNewDocument` silently does nothing until `Page.enable` has been called; and that test pages in temporary directories are gone by the time coverage is converted (see 0006).

Requiring a local baseline before publishing a number also turned up a problem unrelated to the assistant. The local R library was missing seven of the package's Suggests, so the sqlglot, arrow, dtplyr, duckplyr, and emit tests had been skipping without any sign of it. A green local run had said nothing about those engines. The CI runner for the browser tests now fails on skipped tests as well as failures for the same reason.

## Revisit if

This is a working practice with no expiry. If a new class of recall error shows up, write a new record.
