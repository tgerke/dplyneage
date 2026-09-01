# Building the React Flow Bundle

This guide explains how to build the React Flow JavaScript bundle that
powers the visualization component of dplyneage.

**Note for users**: The bundle should be pre-built when you install the
package. You typically only need to build it if:

- You’re developing the package
- You installed from source without a pre-built bundle
- You’re updating the JavaScript/React code

## Prerequisites

1.  **Node.js** (v18 or higher): Download from
    [nodejs.org](https://nodejs.org/)
2.  **npm** (comes with Node.js)

## Build steps

### Option 1: Using R (from a source checkout)

With your working directory at the root of the dplyneage repository:

``` r

# Check if bundle already exists
dplyneage::has_bundle()

# Build (or force-rebuild) the bundle - internal developer helper
dplyneage:::build_bundle()
dplyneage:::build_bundle(force = TRUE)
```

### Option 2: Using the build script

From the package source directory in a terminal:

``` bash
chmod +x build_bundle.sh
./build_bundle.sh
```

### Option 3: Manual build

``` bash
cd srcjs
npm install
npm run build
```

## What gets built

The build process creates:

- `inst/htmlwidgets/lib/reactflow/reactflow-bundle.min.js` - Complete
  React Flow bundle

This bundle includes:

- React 18.3.1
- ReactDOM 18.3.1
- @xyflow/react (React Flow) 12.10.0
- html-to-image (for the PNG export button)
- All necessary CSS, light and dark (injected automatically)

The bundle exposes everything the widget binding consumes on
`window.ReactFlowBundle`: the React runtime, the `ReactFlow` component
with `Background`, `Controls`, `ControlButton`, `MiniMap`, and `Panel`,
the custom `TableNode` and `LineageEdge` components, the
`getNodesBounds`/`getViewportForBounds` viewport helpers, and `toPng`.
The binding guards each optional export, so a browser holding an older
cached bundle degrades by omission (no minimap, no export button) rather
than failing to render. `srcjs/package-lock.json` is committed so a
rebuild from a fresh clone resolves the same dependency versions that
produced the committed bundle.

## Development mode

For active development with auto-rebuild:

``` bash
cd srcjs
npm run dev
```

This will watch for changes and rebuild automatically.

## Testing after build

``` r

devtools::load_all()

lineage_flow(
  nodes = list(
    list(id = "1", position = list(x = 0, y = 0), 
         data = list(label = "Source")),
    list(id = "2", position = list(x = 250, y = 100), 
         data = list(label = "Transform")),
    list(id = "3", position = list(x = 500, y = 0), 
         data = list(label = "Output"))
  ),
  edges = list(
    list(id = "e1-2", source = "1", target = "2"),
    list(id = "e2-3", source = "2", target = "3")
  )
)
```

If the bundle loads successfully, you’ll see an interactive React Flow
diagram with draggable nodes, pan/zoom controls, and a grid background.

If the bundle doesn’t load, it will fall back to the SVG visualization.

## Troubleshooting

**Bundle not found**: Make sure the build completed successfully and
check that `inst/htmlwidgets/lib/reactflow/reactflow-bundle.min.js`
exists.

**Build fails**:

- Check Node.js version: `node --version` (should be v18+)
- Clear node_modules and rebuild:
  `cd srcjs && rm -rf node_modules && npm install && npm run build`

**Widget shows SVG instead of React Flow**: Check browser console for
errors. The widget will fall back to SVG if React Flow fails to load.

## Development workflow

If you’re modifying the React Flow bundle:

1.  Make changes to `srcjs/src/index.js`
2.  Run `npm run dev` in the `srcjs` directory
3.  Reload the R package with `devtools::load_all()`
4.  Test your changes

The webpack configuration in `srcjs/webpack.config.js` handles bundling
all dependencies into a single minified file.

## Bundle contents

The bundle is created using webpack and includes:

- **React Flow**: The main visualization library
- **React & ReactDOM**: Required for React Flow
- **CSS**: All styling bundled inline
- **Source maps**: For debugging (in development mode)

The bundle is optimized for production with minification and
tree-shaking to reduce file size.
