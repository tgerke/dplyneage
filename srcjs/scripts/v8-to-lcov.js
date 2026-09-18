'use strict';

// Converts the V8 coverage that tests/browser writes (one JSON file per
// browser session, script urls already rewritten to paths on disk) into a
// single lcov file with repo-relative paths.
//
// Usage: node srcjs/scripts/v8-to-lcov.js <coverage-dir> <out.lcov>

const fs = require('node:fs');
const path = require('node:path');
const v8toIstanbul = require('v8-to-istanbul');
const libCoverage = require('istanbul-lib-coverage');
const libReport = require('istanbul-lib-report');
const reports = require('istanbul-reports');

const repoRoot = path.resolve(__dirname, '..', '..');
const widgetJs = path.join(repoRoot, 'inst', 'htmlwidgets', 'lineage_flow.js');
const bundleSrc = path.join(repoRoot, 'srcjs', 'src') + path.sep;

// After source-map remapping the bundle reports every module it contains;
// keep our own sources and drop React, React Flow, and the rest
function isOurs(file) {
  return file === widgetJs || file.startsWith(bundleSrc);
}

async function main() {
  const [covDir, outFile] = process.argv.slice(2);
  if (!covDir || !outFile) {
    throw new Error('Usage: node srcjs/scripts/v8-to-lcov.js <coverage-dir> <out.lcov>');
  }

  const map = libCoverage.createCoverageMap({});
  const files = fs.readdirSync(covDir).filter((f) => f.endsWith('.json'));
  for (const file of files) {
    const { result } = JSON.parse(fs.readFileSync(path.join(covDir, file), 'utf8'));
    for (const script of result) {
      const converter = v8toIstanbul(script.url);
      await converter.load();
      converter.applyCoverage(script.functions);
      const converted = converter.toIstanbul();
      for (const source of Object.keys(converted)) {
        if (isOurs(source)) {
          map.merge({ [source]: converted[source] });
        }
      }
      converter.destroy();
    }
  }

  const context = libReport.createContext({
    dir: path.dirname(path.resolve(outFile)),
    coverageMap: map
  });
  reports.create('lcovonly', {
    file: path.basename(outFile),
    projectRoot: repoRoot
  }).execute(context);

  console.log('Sessions: ' + files.length);
  map.files().forEach((file) => {
    const lines = map.fileCoverageFor(file).toSummary().lines;
    console.log(path.relative(repoRoot, file) + ': ' + lines.pct + '% of ' + lines.total + ' lines');
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
