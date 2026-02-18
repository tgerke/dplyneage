# Package-level variables
.dplyneage <- new.env(parent = emptyenv())

# Package initialization
.onLoad <- function(libname, pkgname) {
  # Declare Python requirements using modern reticulate best practice
  # This replaces older approaches like Config/reticulate in DESCRIPTION
  # or use_virtualenv() calls
  reticulate::py_require("sqlglot>=23.0.0")
  
  # Import sqlglot with delay_load to allow users to configure Python
  # before the module is actually loaded
  .dplyneage$sqlglot <- reticulate::import("sqlglot", delay_load = TRUE)
}

#' Configure Python Environment for dplyneage
#'
#' @description
#' This function is deprecated. Python dependencies are now automatically
#' managed via `py_require()` in the package's `.onLoad()` function.
#' Dependencies will be provisioned automatically in an ephemeral virtual
#' environment when needed.
#'
#' @param method Ignored. Kept for backward compatibility.
#' @param required Ignored. Kept for backward compatibility.
#' @return Invisibly returns TRUE
#' @keywords internal
#' @export
configure_python_env <- function(method = "auto", required = FALSE) {
  .Deprecated(
    msg = paste(
      "configure_python_env() is deprecated.",
      "Python dependencies are now managed automatically via py_require()."
    )
  )
  invisible(TRUE)
}

#' Install sqlglot Python Package
#'
#' Installs the sqlglot Python package required for lineage extraction.
#' Uses the requirements.txt file bundled with the package.
#'
#' @param method Installation method: "auto", "virtualenv", or "conda". Default: "auto"
#' @param envname Name of Python environment to use. Default: "r-dplyneage"
#' @return Invisibly returns NULL
#' @export
install_sqlglot <- function(method = "auto", envname = "r-dplyneage") {
  # Get path to requirements.txt
  requirements_file <- system.file("python/requirements.txt", package = "dplyneage")
  
  if (!file.exists(requirements_file)) {
    stop("Could not find requirements.txt file in package installation", call. = FALSE)
  }
  
  message("Installing sqlglot Python package...")
  message("This may take a few minutes...")
  
  # Install packages from requirements file
  reticulate::py_install(
    packages = "sqlglot",
    envname = envname,
    method = method,
    pip = TRUE
  )
  
  message("Successfully installed sqlglot!")
  message("Restart R and reload the package to use lineage extraction features.")
  
  invisible(NULL)
}

#' Check if Python Dependencies are Available
#'
#' @return Logical indicating whether sqlglot is available
#' @export
has_sqlglot <- function() {
  reticulate::py_module_available("sqlglot")
}

#' Build React Flow Bundle
#'
#' Builds the React Flow JavaScript bundle required for interactive visualizations.
#' This function runs npm install and webpack build in the package's srcjs directory.
#' 
#' Note: Requires Node.js (v18+) and npm to be installed on your system.
#'
#' @param force If TRUE, rebuilds even if bundle already exists. Default: FALSE
#' @return Invisibly returns TRUE if successful, FALSE if failed
#' @export
#' @examples
#' \dontrun{
#' # Build the React Flow bundle
#' build_bundle()
#' 
#' # Force rebuild
#' build_bundle(force = TRUE)
#' }
build_bundle <- function(force = FALSE) {
  # Get package installation directory
  pkg_dir <- system.file(package = "dplyneage")
  
  if (pkg_dir == "") {
    stop("Package 'dplyneage' not found. Please install it first.", call. = FALSE)
  }
  
  # Check if bundle already exists
  bundle_path <- file.path(pkg_dir, "htmlwidgets/lib/reactflow/reactflow-bundle.min.js")
  
  if (!force && file.exists(bundle_path)) {
    message("React Flow bundle already exists at:")
    message("  ", bundle_path)
    message("\nUse build_bundle(force = TRUE) to rebuild.")
    return(invisible(TRUE))
  }
  
  # Path to srcjs directory (only exists in development or if installed from source)
  srcjs_dir <- file.path(pkg_dir, "../../../srcjs")
  
  # For installed packages, srcjs might not be in the standard location
  if (!dir.exists(srcjs_dir)) {
    # Try looking in the package source tree
    srcjs_dir <- file.path(pkg_dir, "srcjs")
  }
  
  if (!dir.exists(srcjs_dir)) {
    stop(
      "Cannot find srcjs directory. The bundle build requires the package source code.\n",
      "If you installed via pak::pak(), the pre-built bundle should already be included.\n",
      "If the bundle is missing, please report this as an issue or install from source.",
      call. = FALSE
    )
  }
  
  # Check for Node.js
  node_check <- system("which node", ignore.stdout = TRUE, ignore.stderr = TRUE)
  if (node_check != 0) {
    stop(
      "Node.js not found. Please install Node.js (v18+) from https://nodejs.org/\n",
      "After installing Node.js, restart R and try again.",
      call. = FALSE
    )
  }
  
  message("Building React Flow bundle...")
  message("This may take a few minutes on first run...")
  
  # Check if node_modules exists
  node_modules <- file.path(srcjs_dir, "node_modules")
  if (!dir.exists(node_modules)) {
    message("\nInstalling npm dependencies...")
    npm_install <- system2("npm", args = c("install"), 
                           stdout = TRUE, stderr = TRUE,
                           env = c("PWD" = srcjs_dir))
    if (!is.null(attr(npm_install, "status")) && attr(npm_install, "status") != 0) {
      message(paste(npm_install, collapse = "\n"))
      stop("npm install failed", call. = FALSE)
    }
  }
  
  # Run build
  message("\nRunning webpack build...")
  build_result <- system2("npm", args = c("run", "build"),
                         stdout = TRUE, stderr = TRUE,
                         env = c("PWD" = srcjs_dir))
  
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

#' Check if React Flow Bundle Exists
#'
#' @return Logical indicating whether the React Flow bundle is available
#' @export
has_bundle <- function() {
  bundle_path <- system.file("htmlwidgets/lib/reactflow/reactflow-bundle.min.js", 
                             package = "dplyneage")
  file.exists(bundle_path) && file.size(bundle_path) > 0
}
