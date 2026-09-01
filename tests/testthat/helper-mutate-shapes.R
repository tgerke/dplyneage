# Mutate-family shapes shared by every engine's test file: one table of
# pipelines with the typed edges and output columns each must produce,
# run through run_mutate_shapes() on each backend. Expectations were
# established by hand across all five paths (dbplyr walker, dbplyr
# rendered for sqlglot, dtplyr, arrow, duckplyr). Engines that render
# window functions differently, or cannot run a shape at all, override
# per engine, so a backend that changes its behavior turns the test red
# rather than silently skipping.

mutate_df <- function() {
  data.frame(
    id = 1:6, g = c("x", "x", "y", "y", "z", "z"),
    a = as.numeric(1:6), b = 10 * (1:6), c = 2,
    d = c(NA, 1, NA, 2, NA, 3), s = letters[1:6],
    stringsAsFactors = FALSE
  )
}
mutate_cols <- c("id", "g", "a", "b", "c", "d", "s")
except <- function(...) setdiff(mutate_cols, c(...))

# Notation: "src -> target [kind]"; the runner prepends the source node
edge <- function(src, target, kind) {
  paste0(src, " -> ", target, " [", kind, "]")
}
tf <- function(src, target) edge(src, target, "transformation")
agg <- function(src, target) edge(src, target, "aggregation")
idn <- function(src, target = src) edge(src, target, "identity")
passthrough <- function(cols = mutate_cols) idn(cols)

# Per-engine expected failures, matched against the error message
fails_with <- function(pattern) list(error = pattern)
duckplyr_fallback <- function() fails_with("fell back to eager dplyr")
pulls_into_r <- function() fails_with("plain data frame")
no_predicates <- function() fails_with("support predicates")

edge_targets <- function(edges) {
  unique(sub("^.* -> (\\S+) \\[.*$", "\\1", edges))
}

# `columns` defaults to the edge targets; `ordered = TRUE` also pins
# their order (for .before and relocate()); `indirect` lists the
# "col [kind]" sources include_indirect = TRUE adds; `...` are engine
# overrides (dbplyr, sqlglot, dtplyr, arrow, duckplyr), each a list of
# replacement fields or fails_with()
mutate_shape <- function(pipeline, edges, columns = NULL, ordered = FALSE,
                         indirect = character(), ...) {
  list(
    pipeline = pipeline,
    edges = edges,
    columns = columns %||% edge_targets(edges),
    ordered = ordered,
    indirect = indirect,
    overrides = list(...)
  )
}

resolve_mutate_shape <- function(spec, engine) {
  ov <- spec$overrides[[engine]]
  if (is.null(ov)) {
    return(spec)
  }
  if (!is.null(ov$error)) {
    return(list(pipeline = spec$pipeline, error = ov$error))
  }
  for (field in c("edges", "columns", "indirect", "ordered")) {
    if (!is.null(ov[[field]])) {
      spec[[field]] <- ov[[field]]
    }
  }
  spec
}

# Expand a spec into the sorted "source.col -> target [kinds]" strings
# edge_kind_set() produces: the direct edges, plus (with include_indirect)
# each indirect column fanned out to every output column no direct edge
# from it already reaches, kinds merged per pair, as
# convert_lineage_to_graph() does
expected_mutate_edges <- function(spec, source, include_indirect) {
  parse <- function(x) {
    m <- regmatches(x, regexec("^(\\S+) -> (\\S+) \\[([a-z_]+)\\]$", x))
    data.frame(
      src = vapply(m, `[`, "", 2),
      target = vapply(m, `[`, "", 3),
      kind = vapply(m, `[`, "", 4),
      stringsAsFactors = FALSE
    )
  }
  direct <- parse(spec$edges)
  rows <- direct
  if (include_indirect) {
    for (entry in spec$indirect) {
      col <- sub(" \\[.*$", "", entry)
      kind <- sub("^.* \\[(.*)\\]$", "\\1", entry)
      for (target in spec$columns) {
        if (any(direct$src == col & direct$target == target)) next
        rows <- rbind(
          rows,
          data.frame(src = col, target = target, kind = kind)
        )
      }
    }
  }
  keys <- paste(rows$src, rows$target)
  sort(unname(vapply(
    split(rows, keys),
    function(d) {
      paste0(
        source, ".", d$src[[1]], " -> ", d$target[[1]],
        " [", paste(sort(unique(d$kind)), collapse = ","), "]"
      )
    },
    character(1)
  )))
}

output_columns <- function(lineage) {
  for (n in lineage$nodes) {
    if (identical(n$id, "output")) {
      return(as.character(unlist(n$data$columns)))
    }
  }
  character(0)
}

# `input(df)` wraps the fixture for the backend; `extract(x, ii)` runs
# extract_lineage() with that engine's arguments
run_mutate_shapes <- function(engine, input, extract, source = "df",
                              shapes = mutate_shapes()) {
  for (nm in names(shapes)) {
    spec <- resolve_mutate_shape(shapes[[nm]], engine)
    for (include_indirect in c(FALSE, TRUE)) {
      label <- paste0(
        engine, "/", nm, if (include_indirect) " (indirect)" else ""
      )
      run <- function() {
        extract(spec$pipeline(input(mutate_df())), include_indirect)
      }
      if (!is.null(spec$error)) {
        testthat::expect_error(
          suppressWarnings(run()), spec$error, label = label
        )
        next
      }
      lineage <- run()
      testthat::expect_identical(
        edge_kind_set(lineage),
        expected_mutate_edges(spec, source, include_indirect),
        label = label
      )
      cols <- output_columns(lineage)
      testthat::expect_identical(sort(cols), sort(spec$columns), label = label)
      if (isTRUE(spec$ordered)) {
        testthat::expect_identical(cols, spec$columns, label = label)
      }
    }
  }
}

mutate_shapes <- function() {
  P <- passthrough()
  num <- c("id", "a", "b", "c", "d")
  # SQL backends make a window's partition and order columns direct
  # sources; data.table and Acero have no OVER clause, so dtplyr and
  # arrow keep the keys indirect (arrow's grouped-mutate self-join adds
  # a join kind). Both variants are spelled out where they differ.
  keys_indirect <- function(edges, columns = NULL) {
    list(
      dtplyr = list(
        edges = edges, columns = columns, indirect = "g [group_by]"
      ),
      arrow = list(
        edges = edges, columns = columns,
        indirect = c("g [group_by]", "g [join]")
      )
    )
  }
  window_by_mean <- keys_indirect(c(P, agg("a", "a_mean")))
  window_n <- keys_indirect(P, c(mutate_cols, "n"))
  list(
    # --- projection mechanics -------------------------------------------
    basic = mutate_shape(
      function(x) dplyr::mutate(x, total = a + b),
      edges = c(P, tf(c("a", "b"), "total"))
    ),
    two_cols = mutate_shape(
      function(x) dplyr::mutate(x, total = a + b, ratio = a / c),
      edges = c(P, tf(c("a", "b"), "total"), tf(c("a", "c"), "ratio"))
    ),
    sequential = mutate_shape(
      function(x) dplyr::mutate(x, total = a + b, dbl = total * 2),
      edges = c(P, tf(c("a", "b"), "total"), tf(c("a", "b"), "dbl"))
    ),
    self_overwrite = mutate_shape(
      function(x) dplyr::mutate(x, a = a * 100),
      edges = c(passthrough(except("a")), tf("a", "a"))
    ),
    overwrite_then_use = mutate_shape(
      function(x) dplyr::mutate(x, a = a * 2, b = a + 1),
      edges = c(passthrough(except("a", "b")), tf("a", "a"), tf("a", "b"))
    ),
    drop_null = mutate_shape(
      function(x) dplyr::mutate(x, b = NULL),
      edges = passthrough(except("b")),
      duckplyr = duckplyr_fallback()
    ),
    drop_then_readd = mutate_shape(
      function(x) x |> dplyr::mutate(b = NULL) |> dplyr::mutate(b = a * 3),
      edges = c(passthrough(except("b")), tf("a", "b")),
      columns = c(except("b"), "b"), ordered = TRUE
    ),
    transmute = mutate_shape(
      function(x) dplyr::transmute(x, id, total = a + b),
      edges = c(idn("id"), tf(c("a", "b"), "total"))
    ),
    keep_none = mutate_shape(
      function(x) dplyr::mutate(x, total = a + b, .keep = "none"),
      edges = tf(c("a", "b"), "total")
    ),
    keep_used = mutate_shape(
      function(x) dplyr::mutate(x, total = a + b, .keep = "used"),
      edges = c(idn(c("a", "b")), tf(c("a", "b"), "total"))
    ),
    keep_unused = mutate_shape(
      function(x) dplyr::mutate(x, total = a + b, .keep = "unused"),
      edges = c(passthrough(except("a", "b")), tf(c("a", "b"), "total"))
    ),
    before = mutate_shape(
      function(x) dplyr::mutate(x, total = a + b, .before = id),
      edges = c(P, tf(c("a", "b"), "total")),
      columns = c("total", mutate_cols), ordered = TRUE
    ),

    # --- across() -------------------------------------------------------
    across_formula = mutate_shape(
      function(x) dplyr::mutate(x, dplyr::across(c(a, b), ~ .x * 2)),
      edges = c(passthrough(except("a", "b")), tf(c("a", "b"), c("a", "b")))
    ),
    across_names = mutate_shape(
      function(x) {
        dplyr::mutate(x, dplyr::across(c(a, b), ~ .x * 2, .names = "{.col}_x2"))
      },
      edges = c(P, tf(c("a", "b"), c("a_x2", "b_x2")))
    ),
    across_fnlist = mutate_shape(
      function(x) {
        dplyr::mutate(
          x, dplyr::across(c(a, b), list(sq = ~ .x^2, half = ~ .x / 2))
        )
      },
      edges = c(P, tf("a", c("a_sq", "a_half")), tf("b", c("b_sq", "b_half"))),
      duckplyr = duckplyr_fallback()
    ),
    across_starts_with = mutate_shape(
      function(x) {
        dplyr::mutate(x, dplyr::across(dplyr::starts_with("a"), ~ .x + 1))
      },
      edges = c(passthrough(except("a")), tf("a", "a"))
    ),
    across_fn = mutate_shape(
      function(x) dplyr::mutate(x, dplyr::across(c(a, b), round)),
      edges = c(passthrough(except("a", "b")), tf(c("a", "b"), c("a", "b"))),
      duckplyr = duckplyr_fallback()
    ),
    # dbplyr and dtplyr reject where(); arrow and duckplyr evaluate it
    across_where = mutate_shape(
      function(x) {
        dplyr::mutate(x, dplyr::across(dplyr::where(is.numeric), ~ .x + 1))
      },
      edges = c(idn(c("g", "s")), tf(num, num)),
      dbplyr = no_predicates(), sqlglot = no_predicates(),
      dtplyr = no_predicates()
    ),

    # --- conditionals and functions -------------------------------------
    if_else = mutate_shape(
      function(x) dplyr::mutate(x, flag = dplyr::if_else(a > b, "hi", "lo")),
      edges = c(P, tf(c("a", "b"), "flag"))
    ),
    case_when = mutate_shape(
      function(x) {
        dplyr::mutate(x, bucket = dplyr::case_when(
          a < 2 ~ "low", a < 4 ~ "mid", TRUE ~ "high"
        ))
      },
      edges = c(P, tf("a", "bucket")),
      duckplyr = duckplyr_fallback()
    ),
    case_when_multi = mutate_shape(
      function(x) {
        dplyr::mutate(x, pick1 = dplyr::case_when(a > b ~ c, TRUE ~ d))
      },
      edges = c(P, tf(c("a", "b", "c", "d"), "pick1")),
      duckplyr = duckplyr_fallback()
    ),
    coalesce = mutate_shape(
      function(x) dplyr::mutate(x, x = dplyr::coalesce(d, a)),
      edges = c(P, tf(c("d", "a"), "x"))
    ),
    in_operator = mutate_shape(
      function(x) dplyr::mutate(x, flag = g %in% c("x", "y")),
      edges = c(P, tf("g", "flag")),
      duckplyr = duckplyr_fallback()
    ),
    between = mutate_shape(
      function(x) dplyr::mutate(x, f = dplyr::between(a, 1, 5)),
      edges = c(P, tf("a", "f")),
      duckplyr = duckplyr_fallback()
    ),
    cast = mutate_shape(
      function(x) dplyr::mutate(x, a_chr = as.character(a)),
      edges = c(P, tf("a", "a_chr")),
      duckplyr = duckplyr_fallback()
    ),
    paste = mutate_shape(
      function(x) dplyr::mutate(x, s2 = paste0(s, "_", id)),
      edges = c(P, tf(c("s", "id"), "s2")),
      duckplyr = duckplyr_fallback()
    ),
    literal = mutate_shape(
      function(x) dplyr::mutate(x, one = 1),
      edges = P, columns = c(mutate_cols, "one")
    ),
    n_in_mutate = mutate_shape(
      function(x) dplyr::mutate(x, n = dplyr::n()),
      edges = P, columns = c(mutate_cols, "n")
    ),

    # --- renames, chains, and neighbors ---------------------------------
    copy = mutate_shape(
      function(x) dplyr::mutate(x, new = id),
      edges = c(P, idn("id", "new"))
    ),
    rename = mutate_shape(
      function(x) dplyr::rename(x, amount = a),
      edges = c(passthrough(except("a")), idn("a", "amount"))
    ),
    # A case-preserving rename on purpose: sqlglot lowercases unquoted
    # aliases under the duckdb dialect, so toupper() would not round-trip
    rename_with = mutate_shape(
      function(x) dplyr::rename_with(x, ~ paste0(.x, "_r"), c(a, b)),
      edges = c(passthrough(except("a", "b")), idn(c("a", "b"), c("a_r", "b_r")))
    ),
    relocate = mutate_shape(
      function(x) dplyr::relocate(x, c, .before = a),
      edges = P, columns = c("id", "g", "c", "a", "b", "d", "s"), ordered = TRUE
    ),
    rename_then_mutate = mutate_shape(
      function(x) x |> dplyr::rename(amt = a) |> dplyr::mutate(x = amt * 2),
      edges = c(passthrough(except("a")), idn("a", "amt"), tf("a", "x"))
    ),
    chain = mutate_shape(
      function(x) x |> dplyr::mutate(x = a + 1) |> dplyr::mutate(y = x * 2),
      edges = c(P, tf("a", c("x", "y")))
    ),
    mutate_then_select = mutate_shape(
      function(x) x |> dplyr::mutate(t = a + b) |> dplyr::select(-a),
      edges = c(passthrough(except("a")), tf(c("a", "b"), "t"))
    ),
    ifelse_derived = mutate_shape(
      function(x) {
        dplyr::mutate(x, t = a + b, big = dplyr::if_else(t > 30, 1, 0))
      },
      edges = c(P, tf(c("a", "b"), "t"), tf(c("a", "b"), "big"))
    ),
    mutate_then_summarise = mutate_shape(
      function(x) {
        x |>
          dplyr::mutate(total = a + b) |>
          dplyr::summarise(s = sum(total, na.rm = TRUE), .by = g)
      },
      edges = c(idn("g"), agg(c("a", "b"), "s")),
      indirect = "g [group_by]"
    ),
    group_transmute = mutate_shape(
      function(x) {
        x |>
          dplyr::group_by(g) |>
          dplyr::transmute(total = a + b) |>
          dplyr::ungroup()
      },
      edges = c(idn("g"), tf(c("a", "b"), "total")),
      duckplyr = duckplyr_fallback()
    ),
    mutate_then_filter = mutate_shape(
      function(x) x |> dplyr::mutate(t = a + b) |> dplyr::filter(t > 30),
      edges = c(P, tf(c("a", "b"), "t")),
      indirect = c("a [filter]", "b [filter]")
    ),
    filter_then_mutate = mutate_shape(
      function(x) x |> dplyr::filter(a > 2) |> dplyr::mutate(t = a + b),
      edges = c(P, tf(c("a", "b"), "t")),
      indirect = "a [filter]"
    ),

    # --- window shapes: SQL-style default, keys-indirect overrides ------
    by_mean = mutate_shape(
      function(x) dplyr::mutate(x, a_mean = mean(a, na.rm = TRUE), .by = g),
      edges = c(P, agg(c("a", "g"), "a_mean")),
      dtplyr = window_by_mean$dtplyr, arrow = window_by_mean$arrow
    ),
    group_mutate = mutate_shape(
      function(x) {
        x |>
          dplyr::group_by(g) |>
          dplyr::mutate(a_mean = mean(a, na.rm = TRUE)) |>
          dplyr::ungroup()
      },
      edges = c(P, agg(c("a", "g"), "a_mean")),
      dtplyr = window_by_mean$dtplyr, arrow = window_by_mean$arrow,
      duckplyr = duckplyr_fallback()
    ),
    across_by = mutate_shape(
      function(x) {
        dplyr::mutate(
          x,
          dplyr::across(
            c(a, b), ~ .x - mean(.x, na.rm = TRUE), .names = "{.col}_c"
          ),
          .by = g
        )
      },
      edges = c(P, agg(c("a", "g"), "a_c"), agg(c("b", "g"), "b_c")),
      dtplyr = list(
        edges = c(P, agg("a", "a_c"), agg("b", "b_c")),
        indirect = "g [group_by]"
      ),
      # arrow hoists the mean into an aggregation self-join, so the
      # projection that subtracts it is a plain transformation
      arrow = list(
        edges = c(P, tf("a", "a_c"), tf("b", "b_c")),
        indirect = c("g [group_by]", "g [join]")
      )
    ),
    n_by = mutate_shape(
      function(x) dplyr::mutate(x, n = dplyr::n(), .by = g),
      edges = c(P, agg("g", "n")),
      dtplyr = window_n$dtplyr, arrow = window_n$arrow
    ),
    add_count = mutate_shape(
      function(x) dplyr::add_count(x, g),
      edges = c(P, agg("g", "n")),
      dtplyr = window_n$dtplyr, arrow = window_n$arrow,
      duckplyr = duckplyr_fallback()
    ),
    lag_cumsum = mutate_shape(
      function(x) {
        x |>
          dplyr::arrange(id) |>
          dplyr::mutate(prev = dplyr::lag(a), cum = cumsum(a))
      },
      edges = c(P, tf(c("a", "id"), "prev"), tf(c("a", "id"), "cum")),
      indirect = "id [sort]",
      # LAG and a windowed SUM are AggFunc in sqlglot
      sqlglot = list(
        edges = c(P, agg(c("a", "id"), "prev"), agg(c("a", "id"), "cum"))
      ),
      dtplyr = list(edges = c(P, tf("a", "prev"), tf("a", "cum"))),
      arrow = pulls_into_r(),
      duckplyr = duckplyr_fallback()
    ),
    grouped_window = mutate_shape(
      function(x) {
        x |>
          dplyr::group_by(g) |>
          dplyr::arrange(id) |>
          dplyr::mutate(rn = dplyr::row_number(), prev = dplyr::lag(a)) |>
          dplyr::ungroup()
      },
      edges = c(P, tf(c("g", "id"), "rn"), tf(c("a", "g", "id"), "prev")),
      indirect = "id [sort]",
      sqlglot = list(
        edges = c(P, tf(c("g", "id"), "rn"), agg(c("a", "g", "id"), "prev"))
      ),
      dtplyr = list(
        edges = c(P, tf("a", "prev")),
        columns = c(mutate_cols, "rn", "prev"),
        indirect = c("g [group_by]", "id [sort]")
      ),
      arrow = pulls_into_r(),
      duckplyr = duckplyr_fallback()
    )
  )
}
