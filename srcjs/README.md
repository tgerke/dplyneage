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

CI runs the same tests with coverage from the repository root (see `.github/workflows/test-coverage.yaml`). The React Flow render path is not covered yet because it needs a browser.

## What Gets Bundled

- React 18.2.0
- ReactDOM 18.2.0  
- @xyflow/react (React Flow) 12.10.0
- React Flow CSS styles (injected automatically)

The bundle exposes everything via `window.ReactFlowBundle` for use by htmlwidgets.
