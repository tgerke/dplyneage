#!/bin/bash
# Build script for React Flow bundle

echo "Building React Flow bundle for dplyneage..."

cd srcjs

# Check if node_modules exists
if [ ! -d "node_modules" ]; then
    echo "Installing npm dependencies..."
    npm install
fi

echo "Running webpack build..."
npm run build

if [ $? -eq 0 ]; then
    echo "✓ Build successful!"
    echo "Bundle created at: inst/htmlwidgets/lib/reactflow/reactflow-bundle.min.js"
    ls -lh ../inst/htmlwidgets/lib/reactflow/reactflow-bundle.min.js 2>/dev/null || echo "Warning: Bundle file not found"
else
    echo "✗ Build failed"
    exit 1
fi
