# 0005. Test the rendered widget with chromote, outside `tests/testthat`

Date: 2026-09-18. Status: accepted.

## Context

After 0003, the React Flow render path in `lineage_flow.js` and the `TableNode` and `LineageEdge` components in `srcjs/src/index.js` were still untested, because they depend on a browser's layout engine. jsdom has no `ResizeObserver` and no meaningful `getBoundingClientRect()`. The recent widget bugs were measurement bugs: `srcjs/patches/@xyflow+system+0.0.74.patch` corrects handle offsets when an ancestor scales the widget with CSS, as a reveal.js slide does. Nothing guarded that patch.

## Decision

The tests live in `tests/browser/` and drive headless Chrome over the DevTools protocol with the chromote R package, inside testthat. Each test builds its own page from R under `load_all`, so fixtures cannot drift from what R emits. The helper polls for state instead of sleeping, sends pointer and key events through Chrome's input pipeline, and records page exceptions and `console.error` calls.

The directory is listed in `.Rbuildignore`. The tests are never in the built package, so they cannot run in `R CMD check`, on CRAN, or on the three-OS check matrix, and chromote stays out of `DESCRIPTION`. CI runs them through `.github/scripts/browser-tests.R`, which fails on skipped tests too.

## Alternatives considered

Playwright. Its auto-waiting is better than hand-rolled polling. It also means a second test ecosystem, an npm toolchain, and a browser download for a sole maintainer who works in R, and the fixtures would still have to come from R.

Putting the tests in `tests/testthat` behind skip conditions. chromote would then belong in Suggests, the files would ship to CRAN, and one wrong gate would launch Chrome on a CRAN machine. Keeping them out of the tarball removes that risk by construction.

## How it was decided and checked

Proposed by the assistant with chromote as its recommendation; approved by the maintainer. React Flow's class names and data attributes were read from the live DOM in a spike, not taken from recall.

The alignment test measures the screen-space distance between each end of every edge and the handle it should touch. With the shipped bundle the distance is 0.000 px, plain and under `transform: scale()`. With the patch reversed, edges under a scale miss their handles by 51 to 335 px and the test fails. The patch was re-applied afterwards, and a fresh production build matched the committed bundle byte for byte.

Four deliberate breaks each failed tests: cone dimming, `colorMode`, the hidden-container guard, and the Shiny input name. Five consecutive local runs passed, at about 14 seconds each. The first CI run passed with 161 checks and no skips.

One failure during development was the test's fault. After a traced cone is released by a click or by Escape, the pointer still rests on the row, so hover dimming correctly remains. The assertion now looks for the cone's own opacity value.

## Revisit if

The job flakes in CI. The fix is a more specific wait, not a blanket retry that would hide a real failure. Also revisit if the suite outgrows what hand-rolled waits handle comfortably.
