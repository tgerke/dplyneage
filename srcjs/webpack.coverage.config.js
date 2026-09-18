const path = require('path');
const base = require('./webpack.config.js');

// The shipped production build plus a source map, so browser coverage of the
// bundle can be attributed to src/index.js. It writes outside inst/ and never
// touches the tracked bundle. Absolute source paths let the converter tell
// src/ from node_modules.
module.exports = Object.assign({}, base, {
  mode: 'production',
  devtool: 'source-map',
  output: Object.assign({}, base.output, {
    path: path.resolve(process.env.DPLYNEAGE_BUNDLE_OUT || path.join(__dirname, 'coverage-build')),
    devtoolModuleFilenameTemplate: '[absolute-resource-path]'
  })
});
