# React Flow Bundle for dplyneage

This directory contains the JavaScript source and build configuration for bundling React Flow for use in the R package.

## Setup

1. Install Node.js (version 18 or higher recommended)
2. Install dependencies:

```bash
npm install
```

## Build

To build the production bundle:

```bash
npm run build
```

This will create `inst/htmlwidgets/lib/reactflow/reactflow-bundle.min.js` which the R package will use.

For development with auto-rebuild:

```bash
npm run dev
```

## Test

The unit tests cover the parts of `inst/htmlwidgets/lineage_flow.js` that run without a browser. They use Node's built-in test runner, so there is nothing to install:

```bash
npm test
```

The React Flow render path depends on a browser's layout engine, so it has its own tests in `tests/browser/`. They render widgets in headless Chrome through the chromote R package and check the live DOM: edges meeting their handles (also under an ancestor CSS scale, which is what the `@xyflow/system` patch fixes), cone tracing, hover cards, themes, re-rendering, and PNG export. You need Chrome and chromote. Run them from the repository root:

```bash
Rscript .github/scripts/browser-tests.R
```

That run uses the shipped bundle. The directory is listed in `.Rbuildignore`, so these tests never run in `R CMD check` or on CRAN.

To collect browser coverage, build a source-mapped copy of the bundle first. It goes to `srcjs/coverage-build/`, which git ignores, and the shipped bundle is left alone:

```bash
npx webpack --config webpack.coverage.config.js
```

Then, from the repository root, run the tests against that build and convert the result to lcov:

```bash
DPLYNEAGE_BROWSER_BUNDLE_DIR=srcjs/coverage-build DPLYNEAGE_BROWSER_COVERAGE=srcjs/coverage-build/v8 Rscript .github/scripts/browser-tests.R
```

```bash
node srcjs/scripts/v8-to-lcov.js srcjs/coverage-build/v8 srcjs/coverage-build/browser.lcov
```

CI does all of this in `.github/workflows/test-coverage.yaml` and uploads the unit and browser reports to Codecov under the `js` flag.

## What Gets Bundled

- React 18.2.0
- ReactDOM 18.2.0  
- @xyflow/react (React Flow) 12.10.0
- React Flow CSS styles (injected automatically)

The bundle exposes everything via `window.ReactFlowBundle` for use by htmlwidgets.
