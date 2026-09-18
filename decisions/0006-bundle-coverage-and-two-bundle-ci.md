# 0006. Attribute bundle coverage through a separate source-mapped build

Date: 2026-09-18. Status: accepted.

## Context

The shipped `reactflow-bundle.min.js` is minified and has no source map, so browser coverage of it cannot be traced back to `srcjs/src/index.js`. Building a source map in place would modify a tracked file that ships to CRAN.

## Decision

`srcjs/webpack.coverage.config.js` extends the base config into the same production build plus a source map, written outside `inst/`. When `DPLYNEAGE_BROWSER_BUNDLE_DIR` is set, the browser test helper copies that build over the bundle in each test page. It collects V8 precise coverage through the DevTools `Profiler` domain and writes one JSON file per page.

`srcjs/scripts/v8-to-lcov.js` converts those files with `v8-to-istanbul` and the istanbul report libraries. It keeps `inst/htmlwidgets/lineage_flow.js` and anything under `srcjs/src/`, drops React, React Flow, and the other bundled modules, and writes lcov with repository-relative paths.

The coverage JSON points at files that outlast the tests. Test pages are temporary directories, deleted when each test ends, so the bundle is recorded at its build location and the widget script at its source in `inst/`, after an md5 check that the page held a verbatim copy.

CI runs the browser suite twice: against the shipped bundle, which is what users get, and against the source-mapped build, with coverage. Both reports upload under the `js` flag, where Codecov merges them with the Node unit tests from 0003.

## Alternatives considered

`c8 report` over the raw V8 files. It needs no custom code, but gives less control over scripts that live outside the working directory.

`monocart-coverage-reports`. One dependency where this uses four, but less widely used than the istanbul libraries.

A CI check that the committed bundle matches a fresh build byte for byte. webpack output can differ across platforms, so the check risks false alarms. It was left out. On 2026-09-18 a fresh production build on the maintainer's machine was identical to the committed bundle.

## Known difference between the two bundles

The source-mapped build is about 24 KB larger, because css-loader embeds the CSS source map when `devtool` is set. Behavior is the same. It is one more reason to keep the shipped-bundle pass.

## How it was decided and checked

Proposed by the assistant and approved by the maintainer. A spike proved the whole path for one page (page, V8 JSON, lcov) before the suite was written. The first full run then failed at conversion because the pages had already been deleted, which led to recording lasting paths.

The lcov lists exactly two files. On Codecov the `js` flag reads 97.95% (1,485 of 1,516 lines): `lineage_flow.js` at 97.65% and `srcjs/src/index.js` at 99.29%. The 29 lines still uncovered in `lineage_flow.js` are mostly fallbacks for older cached bundles and the catch that degrades to the static SVG.

## Revisit if

The package starts shipping a source map, or the bundler changes.
