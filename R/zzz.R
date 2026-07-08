# Package-level variables
.dplyneage <- new.env(parent = emptyenv())

# Package initialization
.onLoad <- function(libname, pkgname) {
  # Declare Python requirements; reticulate provisions sqlglot automatically
  # in an ephemeral environment when no user-configured Python is active
  reticulate::py_require("sqlglot>=23.0.0")

  # Import the bundled lineage module with delay_load so Python does not
  # initialize until lineage extraction is first used
  .dplyneage$lineage <- reticulate::import_from_path(
    "dplyneage_lineage",
    path = system.file("python", package = pkgname),
    delay_load = TRUE
  )
}

#' Install sqlglot Python Package
#'
#' @description
#' Deprecated: Python dependencies are managed
#' automatically via `reticulate::py_require()` when the package loads, so no
#' manual installation step is needed. If you manage your own Python
#' environment (e.g. a project virtualenv), install sqlglot into it directly
#' with `pip install sqlglot`.
#'
#' @param method Ignored. Kept for backward compatibility.
#' @param envname Ignored. Kept for backward compatibility.
#' @return Invisibly returns TRUE
#' @keywords internal
#' @export
install_sqlglot <- function(method = "auto", envname = "r-dplyneage") {
  .Deprecated(
    msg = paste(
      "install_sqlglot() is deprecated and does nothing.",
      "Python dependencies are managed automatically via reticulate::py_require()."
    )
  )
  invisible(TRUE)
}

#' Is the Python sqlglot dependency available?
#'
#' dplyneage declares its sqlglot dependency via
#' [reticulate::py_require()], so it is provisioned automatically the first
#' time lineage extraction runs — you should not need to install anything.
#' Use this to check availability, or to gate code that calls
#' [extract_lineage()] (examples, vignette chunks, Shiny apps). Note that
#' calling it may initialize Python.
#'
#' @return `TRUE` if sqlglot can be loaded, `FALSE` otherwise
#' @seealso `vignette("python-integration")` for using your own Python
#'   environment
#' @export
#' @examples
#' \dontrun{
#' has_sqlglot()
#' }
has_sqlglot <- function() {
  reticulate::py_module_available("sqlglot")
}

#' Build React Flow Bundle
#'
#' Developer tool that rebuilds the React Flow JavaScript bundle from the
#' `srcjs/` sources. The bundle ships pre-built with the package, so end
#' users never need this; it only works from a source checkout of the
#' repository (see also `build_bundle.sh`).
#'
#' Requires Node.js (v18+) and npm.
#'
#' @param force If TRUE, rebuilds even if bundle already exists. Default: FALSE
#' @return Invisibly returns TRUE if successful, FALSE if failed
#' @keywords internal
build_bundle <- function(force = FALSE) {
  # This only makes sense from a source checkout, where srcjs/ sits next to
  # inst/ at the repository root
  pkg_root <- normalizePath(".", mustWork = TRUE)
  srcjs_dir <- file.path(pkg_root, "srcjs")
  bundle_path <- file.path(
    pkg_root, "inst", "htmlwidgets", "lib", "reactflow",
    "reactflow-bundle.min.js"
  )

  if (!dir.exists(srcjs_dir)) {
    stop(
      "Cannot find the srcjs/ directory. build_bundle() must be run from ",
      "the root of a source checkout of the dplyneage repository.",
      call. = FALSE
    )
  }

  if (!force && file.exists(bundle_path)) {
    message("React Flow bundle already exists at:")
    message("  ", bundle_path)
    message("\nUse build_bundle(force = TRUE) to rebuild.")
    return(invisible(TRUE))
  }

  # Check for Node.js
  if (Sys.which("node") == "") {
    stop(
      "Node.js not found. Please install Node.js (v18+) from https://nodejs.org/\n",
      "After installing Node.js, restart R and try again.",
      call. = FALSE
    )
  }

  message("Building React Flow bundle...")
  message("This may take a few minutes on first run...")

  # npm must run inside srcjs/
  old_wd <- setwd(srcjs_dir)
  on.exit(setwd(old_wd), add = TRUE)

  if (!dir.exists("node_modules")) {
    message("\nInstalling npm dependencies...")
    npm_install <- system2("npm", args = "install", stdout = TRUE, stderr = TRUE)
    if (!is.null(attr(npm_install, "status")) && attr(npm_install, "status") != 0) {
      message(paste(npm_install, collapse = "\n"))
      stop("npm install failed", call. = FALSE)
    }
  }

  message("\nRunning webpack build...")
  build_result <- system2("npm", args = c("run", "build"), stdout = TRUE, stderr = TRUE)
  if (!is.null(attr(build_result, "status")) && attr(build_result, "status") != 0) {
    message(paste(build_result, collapse = "\n"))
    stop("Build failed", call. = FALSE)
  }

  # Verify bundle was created
  if (file.exists(bundle_path)) {
    bundle_size <- file.size(bundle_path)
    message("\n[OK] Build successful!")
    message("Bundle created at:")
    message("  ", bundle_path)
    message(sprintf("  Size: %.1f KB", bundle_size / 1024))
  } else {
    warning("Build completed but bundle file not found at expected location")
    return(invisible(FALSE))
  }

  invisible(TRUE)
}

#' Is the React Flow bundle available?
#'
#' The JavaScript bundle that powers [lineage_flow()] ships pre-built with
#' the package, so this normally returns `TRUE`. If it returns `FALSE`,
#' diagrams fall back to a static SVG rendering; see
#' `vignette("building-reactflow")` for how to rebuild the bundle from
#' source.
#'
#' @return `TRUE` if the pre-built React Flow bundle is present
#' @export
#' @examples
#' has_bundle()
has_bundle <- function() {
  bundle_path <- system.file("htmlwidgets/lib/reactflow/reactflow-bundle.min.js",
                             package = "dplyneage")
  file.exists(bundle_path) && file.size(bundle_path) > 0
}
