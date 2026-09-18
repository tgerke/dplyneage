# Browser-level tests for the widget: real layout in headless Chrome, driven
# over the DevTools protocol with chromote. They sit outside tests/testthat
# and are .Rbuildignore'd, so they can never run in R CMD check or on CRAN,
# and chromote stays out of DESCRIPTION. Run them from the package root:
#
#   pkgload::load_all(); testthat::test_dir("tests/browser", package = "dplyneage")
#
# Environment variables, all optional:
#   DPLYNEAGE_BROWSER_BUNDLE_DIR  a source-mapped bundle to swap into each page
#                                 (srcjs/webpack.coverage.config.js builds one)
#   DPLYNEAGE_BROWSER_COVERAGE    directory for V8 coverage, one JSON per page
#   DPLYNEAGE_BROWSER_SHOTS       directory for a screenshot of each page

skip_if_no_browser <- function() {
  testthat::skip_if_not_installed("chromote")
  chrome <- tryCatch(suppressMessages(chromote::find_chrome()), error = function(e) NULL)
  testthat::skip_if(is.null(chrome), "Chrome is not available")
}

env_dir <- function(name) {
  path <- Sys.getenv(name)
  if (!nzchar(path)) {
    return(NULL)
  }
  dir.create(path, showWarnings = FALSE, recursive = TRUE)
  normalizePath(path)
}

q <- function(x) jsonlite::toJSON(x, auto_unbox = TRUE)

# Small in-page toolkit. Handles are matched by attribute comparison, as the
# widget does, because column names can hold characters a CSS selector would
# need escaped.
js_toolkit <- "
window.__t = {
  all: function(selector) { return Array.prototype.slice.call(document.querySelectorAll(selector)); },
  handle: function(nodeId, handleId, type) {
    return this.all('.react-flow__handle').find(function(h) {
      return h.dataset.nodeid === nodeId && h.dataset.handleid === handleId && h.classList.contains(type);
    });
  },
  row: function(nodeId, handleId) { return this.handle(nodeId, handleId, 'source').parentElement; },
  node: function(nodeId) {
    return this.all('.react-flow__node').find(function(n) { return n.dataset.id === nodeId; });
  },
  card: function(nodeId) { return this.node(nodeId).firstElementChild; },
  edge: function(edgeId) {
    return this.all('.react-flow__edge').find(function(g) { return g.dataset.id === edgeId; });
  },
  path: function(edgeId) { return this.edge(edgeId).querySelector('.react-flow__edge-path'); },
  center: function(el) {
    var r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  },
  // A point on the edge in screen space; t runs from 0 (source) to 1 (target)
  pointOn: function(edgeId, t) {
    var p = this.path(edgeId);
    var pt = p.getPointAtLength(p.getTotalLength() * t).matrixTransform(p.getScreenCTM());
    return { x: pt.x, y: pt.y };
  },
  zoom: function() {
    return new DOMMatrixReadOnly(getComputedStyle(document.querySelector('.react-flow__viewport')).transform).a;
  },
  legend: function() {
    var panel = document.querySelector('.react-flow__panel.top.right');
    return panel ? panel.innerText.split('\\n') : null;
  }
};
"

# Renders `widget` to a page, opens it in a fresh Chrome tab, and returns a
# handle for the helpers below. Everything is torn down with the calling test.
#   wrap         function(widget) returning tags, to place the widget inside
#                a scaled or hidden ancestor
#   before_load  JavaScript to run before any page script
#   ready        FALSE skips the wait for a mounted graph
local_widget_page <- function(widget, wrap = identity, before_load = NULL,
                              ready = TRUE, env = parent.frame()) {
  skip_if_no_browser()

  dir <- withr::local_tempdir(.local_envir = env)
  file <- file.path(dir, "index.html")
  htmltools::save_html(htmltools::tagList(wrap(widget)), file = file, libdir = "lib")

  find_copy <- function(name) {
    normalizePath(list.files(dir, pattern = paste0("^", name, "$"), recursive = TRUE, full.names = TRUE))
  }
  bundle_copy <- find_copy("reactflow-bundle[.]min[.]js")
  bundle_dir <- env_dir("DPLYNEAGE_BROWSER_BUNDLE_DIR")
  if (!is.null(bundle_dir)) {
    # The widget dependency copies only the bundle itself, so the source
    # map has to be placed next to it by hand
    built <- file.path(bundle_dir, c("reactflow-bundle.min.js", "reactflow-bundle.min.js.map"))
    stopifnot(file.exists(built))
    file.copy(built, dirname(bundle_copy), overwrite = TRUE)
  }

  b <- chromote::ChromoteSession$new(width = 1400, height = 1000)
  b$Emulation$setDeviceMetricsOverride(
    width = 1400, height = 1000, deviceScaleFactor = 1, mobile = FALSE
  )
  # Uncaught exceptions and console.error calls, which is where the widget
  # reports a failed React render before falling back to the static SVG
  problems <- new.env()
  problems$seen <- character()
  b$Runtime$enable()
  b$Runtime$exceptionThrown(callback = function(msg) {
    detail <- msg$exceptionDetails
    text <- if (is.null(detail$exception$description)) detail$text else detail$exception$description
    problems$seen <- c(problems$seen, text)
  })
  b$Runtime$consoleAPICalled(callback = function(msg) {
    if (identical(msg$type, "error")) {
      args <- vapply(msg$args, function(a) as.character(c(a$value, a$description, "")[1]), "")
      problems$seen <- c(problems$seen, paste(args, collapse = " "))
    }
  })
  page <- list(b = b, dir = dir, x = widget$x, problems = problems)

  cov_dir <- env_dir("DPLYNEAGE_BROWSER_COVERAGE")
  if (!is.null(cov_dir)) {
    b$Profiler$enable()
    b$Profiler$startPreciseCoverage(callCount = TRUE, detailed = TRUE)
  }

  withr::defer({
    shots <- env_dir("DPLYNEAGE_BROWSER_SHOTS")
    if (!is.null(shots)) {
      try(b$screenshot(tempfile("page-", shots, ".png"), show = FALSE), silent = TRUE)
    }
    if (!is.null(cov_dir)) {
      write_coverage(b, cov_dir, find_copy("lineage_flow[.]js"), bundle_copy, !is.null(bundle_dir))
    }
    try(b$close(), silent = TRUE)
  }, envir = env)

  if (!is.null(before_load)) {
    b$Page$addScriptToEvaluateOnNewDocument(source = before_load)
  }
  b$Page$navigate(paste0("file://", normalizePath(file)))
  wait_for(page, "document.readyState === 'complete' && typeof HTMLWidgets !== 'undefined'")
  js(page, js_toolkit)
  if (ready) {
    wait_for_flow(page)
  }
  page
}

# The converter reads scripts from disk, so every url becomes a path: the
# widget script maps back to its source in inst/ (the page holds a verbatim
# copy), the bundle stays where its source map was placed.
write_coverage <- function(b, cov_dir, widget_copy, bundle_copy, has_map) {
  widget_src <- normalizePath(file.path(pkgload::pkg_path(), "inst", "htmlwidgets", "lineage_flow.js"))
  stopifnot(identical(unname(tools::md5sum(widget_copy)), unname(tools::md5sum(widget_src))))

  scripts <- list()
  for (script in b$Profiler$takePreciseCoverage()$result) {
    if (endsWith(script$url, "/lineage_flow.js")) {
      script$url <- widget_src
    } else if (has_map && endsWith(script$url, "/reactflow-bundle.min.js")) {
      script$url <- bundle_copy
    } else {
      next
    }
    scripts[[length(scripts) + 1]] <- script
  }
  jsonlite::write_json(
    list(result = scripts),
    tempfile("session-", cov_dir, ".json"),
    auto_unbox = TRUE, digits = NA
  )
}

js <- function(page, expr) {
  res <- page$b$Runtime$evaluate(expr, returnByValue = TRUE, awaitPromise = TRUE)
  if (!is.null(res$exceptionDetails)) {
    detail <- res$exceptionDetails$exception$description
    stop("JavaScript error in `", expr, "`: ", if (is.null(detail)) res$exceptionDetails$text else detail, call. = FALSE)
  }
  res$result$value
}

# Polls instead of sleeping: fast when the page is fast, patient when CI is slow
wait_for <- function(page, expr, timeout = 15) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(js(page, expr))) {
      return(invisible(TRUE))
    }
    if (Sys.time() > deadline) {
      stop("Timed out after ", timeout, "s waiting for: ", expr, call. = FALSE)
    }
    Sys.sleep(0.05)
  }
}

# Waits until `expr` returns the same value on five consecutive polls
wait_stable <- function(page, expr, timeout = 15) {
  deadline <- Sys.time() + timeout
  last <- NULL
  same <- 0
  repeat {
    value <- js(page, expr)
    same <- if (identical(value, last)) same + 1 else 0
    last <- value
    if (same >= 5) {
      return(value)
    }
    if (Sys.time() > deadline) {
      stop("Timed out after ", timeout, "s waiting for a stable: ", expr, call. = FALSE)
    }
    Sys.sleep(0.05)
  }
}

# Mounted, measured, and done with its initial fitView
wait_for_flow <- function(page, n_nodes = length(page$x$nodes), n_edges = length(page$x$edges)) {
  wait_for(page, sprintf(
    "__t.all('.react-flow__node').length === %d &&
     __t.all('.react-flow__edge-path').length === %d &&
     __t.all('.react-flow__node').every(function(n) { return n.getBoundingClientRect().width > 0; })",
    n_nodes, n_edges
  ))
  wait_stable(page, "document.querySelector('.react-flow__viewport').style.transform")
  invisible(page)
}

# Real pointer and key events through Chrome's input pipeline, so hit testing
# and React's synthetic events behave as they do for a person
mouse_move <- function(page, point) {
  page$b$Input$dispatchMouseEvent(type = "mouseMoved", x = point$x, y = point$y)
  invisible(page)
}

mouse_click <- function(page, point) {
  mouse_move(page, point)
  for (type in c("mousePressed", "mouseReleased")) {
    page$b$Input$dispatchMouseEvent(
      type = type, x = point$x, y = point$y, button = "left", clickCount = 1
    )
  }
  invisible(page)
}

press_escape <- function(page) {
  for (type in c("keyDown", "keyUp")) {
    page$b$Input$dispatchKeyEvent(
      type = type, key = "Escape", code = "Escape", windowsVirtualKeyCode = 27
    )
  }
  invisible(page)
}

click_column <- function(page, node, column) {
  mouse_click(page, js(page, sprintf("__t.center(__t.row(%s, %s))", q(node), q(column))))
}

hover_column <- function(page, node, column) {
  mouse_move(page, js(page, sprintf("__t.center(__t.row(%s, %s))", q(node), q(column))))
}

# Fixtures ---------------------------------------------------------------

# A filter, a computed column, and a labelled source column: direct and
# indirect edges, an edge label, an expression, and hover metadata, all from
# the pure-R engine
rich_widget <- function(...) {
  testthat::skip_if_not_installed("dplyr")
  testthat::skip_if_not_installed("dbplyr", "2.5.0")

  df <- data.frame(id = 1L, amount = 2.5, region = "x")
  attr(df$amount, "label") <- "Order amount"
  lineage <- dbplyr::tbl_lazy(df, name = "orders") |>
    dplyr::filter(region == "x") |>
    dplyr::mutate(doubled = amount * 2) |>
    dplyr::select(id, doubled) |>
    extract_lineage(engine = "r", include_indirect = TRUE)
  lineage_flow(lineage, ...)
}
