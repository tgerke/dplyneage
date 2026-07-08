# Build React Flow Bundle

Developer tool that rebuilds the React Flow JavaScript bundle from the
`srcjs/` sources. The bundle ships pre-built with the package, so end
users never need this; it only works from a source checkout of the
repository (see also `build_bundle.sh`).

## Usage

``` r
build_bundle(force = FALSE)
```

## Arguments

- force:

  If TRUE, rebuilds even if bundle already exists. Default: FALSE

## Value

Invisibly returns TRUE if successful, FALSE if failed

## Details

Requires Node.js (v18+) and npm.
