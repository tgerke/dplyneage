# 0003. Unit-test the widget's browser-free code with Node's test runner

Date: 2026-09-17. Status: accepted.

## Context

`inst/htmlwidgets/lineage_flow.js` is a classic browser script of about 1,200 lines, and it had no tests. Roughly half of it runs without a browser: lane assignment, cone walking, theming, the legend and hover card, PNG export sizing, the resize watcher, and the static SVG fallback. The SVG fallback writes `innerHTML`, so its escaping is the one security-relevant path in the file.

## Decision

`srcjs/tests/lineage_flow.test.js` uses `node:test` and `node:assert`, with no npm packages. The CI job runs `node --test` with the built-in lcov reporter from the repository root, so the report's paths match the repository and there is no `npm ci` step.

The script's only load-time statement is `HTMLWidgets.widget(...)`, so a one-object stub lets Node load it. A guarded `module.exports` block at the bottom of the widget file hands the helpers to the tests. Browsers define no `module`, so the block never runs in the widget.

## Alternatives considered

Jest or Vitest with jsdom. That adds dependencies, and jsdom has no layout, so it could not reach the render path anyway.

Loading the script through `node:vm`, which would leave the shipped file untouched. Whether coverage gets attributed to a vm-loaded script depends on the runner's internals, and a five-line export is easier to reason about.

## How it was decided and checked

The maintainer chose this scope from three options the assistant laid out: R and Python only, Node unit tests now, or Node tests plus a browser harness in one change. The assistant recommended the middle option and measured the file first to say how much of it Node could reach.

The suite has 55 tests. Four deliberate breaks each made tests fail: the lane order, the label escaping, the upstream cone walk, and the PNG size cap. The widget file was then restored byte for byte. With the export block in place the widget rendered in headless Chrome with no errors, and `typeof module` was `undefined` in the page.

## Consequences

A test-only export ships in the package. It is inert in a browser.

## Revisit if

The widget file becomes an ES module or gains a build step. Either one removes the need for the guarded export.
