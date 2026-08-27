# Programmatic lineage API: print method, data frame accessors, diffs,
# and impact traversals. Engine-free: graphs come from
# convert_lineage_to_graph() on the shared fixture or the manual builders.

api_fixture_graph <- function() {
  convert_lineage_to_graph(fixture_lineage())
}

# a -> b -> c chain for transitive traversal tests
chain_graph <- function() {
  list(
    nodes = list(
      create_table_node("a", "x"),
      create_table_node("b", "y", table_type = "transform"),
      create_table_node("c", "z", table_type = "target")
    ),
    edges = list(
      create_column_edge("a", "x", "b", "y"),
      create_column_edge("b", "y", "c", "z")
    )
  )
}

test_that("extract_lineage results carry the dplyneage_lineage class", {
  expect_s3_class(api_fixture_graph(), "dplyneage_lineage")
})

test_that("print method summarises the lineage", {
  expect_snapshot(print(api_fixture_graph()))
})

test_that("lineage_edges returns one classified row per edge", {
  edges <- lineage_edges(api_fixture_graph())

  expect_s3_class(edges, "data.frame")
  expect_identical(nrow(edges), 2L)
  expect_named(
    edges,
    c(
      "source_table", "source_column", "target_table", "target_column",
      "transformation", "expression"
    )
  )

  agg <- edges[edges$target_column == "total_spent", ]
  expect_identical(agg$source_table, "orders")
  expect_identical(agg$transformation, "aggregation")
  expect_identical(agg$expression, "SUM(amount)")

  passthrough <- edges[edges$target_column == "customer_id", ]
  expect_identical(passthrough$transformation, "identity")
})

test_that("hand-built edges get NA classification", {
  edges <- lineage_edges(chain_graph())
  expect_identical(edges$transformation, c(NA_character_, NA_character_))
  expect_identical(edges$expression, c(NA_character_, NA_character_))
})

test_that("lineage_edges of an edge-free lineage is a 0-row data frame", {
  lineage <- list(nodes = list(create_table_node("a", "x")), edges = list())
  edges <- lineage_edges(lineage)
  expect_identical(nrow(edges), 0L)
  expect_named(
    edges,
    c(
      "source_table", "source_column", "target_table", "target_column",
      "transformation", "expression"
    )
  )
})

test_that("lineage_tables summarises nodes", {
  tables <- lineage_tables(api_fixture_graph())

  expect_identical(
    tables[order(tables$table), ]$table,
    c("customers", "orders", "output")
  )
  expect_identical(tables$type[tables$table == "output"], "target")
  expect_identical(tables$n_columns[tables$table == "output"], 2L)
})

test_that("upstream and downstream traversals are transitive", {
  g <- chain_graph()

  expect_identical(lineage_upstream(g, "c.z"), c("a.x", "b.y"))
  expect_identical(lineage_downstream(g, "a.x"), c("b.y", "c.z"))
  expect_identical(lineage_upstream(g, "a.x"), character(0))
  expect_identical(lineage_downstream(g, "c.z"), character(0))
})

test_that("traversals reject columns not in the lineage", {
  expect_error(
    lineage_upstream(chain_graph(), "nope.nope"),
    "table.column"
  )
})

test_that("lineage_diff reports added and removed edges and columns", {
  old <- api_fixture_graph()

  new_lineage <- fixture_lineage()
  # drop the total_spent aggregation, add a new email passthrough
  new_lineage$columns[[2]] <- list(
    output_name = "email",
    expression = "email",
    type = "identity",
    sources = list(list(table = "customers", column_name = "email"))
  )
  new <- convert_lineage_to_graph(new_lineage)

  diff <- lineage_diff(old, new)

  expect_s3_class(diff, "dplyneage_lineage_diff")
  expect_identical(diff$added_edges$source_column, "email")
  expect_identical(diff$removed_edges$source_column, "amount")
  expect_in("customers.email", paste0(diff$added_columns$table, ".", diff$added_columns$column))
  expect_in("orders.amount", paste0(diff$removed_columns$table, ".", diff$removed_columns$column))

  expect_snapshot(print(diff))
})

test_that("identical lineages diff to no changes", {
  diff <- lineage_diff(api_fixture_graph(), api_fixture_graph())
  expect_identical(sum(vapply(diff, nrow, integer(1))), 0L)
  expect_snapshot(print(diff))
})

test_that("lineage_diff reports edges whose definition changed", {
  old <- api_fixture_graph()
  altered <- fixture_lineage()
  altered$columns[[2]]$expression <- "AVG(amount)"
  new <- convert_lineage_to_graph(altered)

  diff <- lineage_diff(old, new)
  expect_identical(nrow(diff$added_edges), 0L)
  expect_identical(nrow(diff$removed_edges), 0L)
  expect_identical(nrow(diff$changed_edges), 1L)
  expect_identical(diff$changed_edges$old_expression, "SUM(amount)")
  expect_identical(diff$changed_edges$new_expression, "AVG(amount)")
  expect_snapshot(print(diff))
})

test_that("lineage_has_changes answers for CI", {
  old <- api_fixture_graph()
  altered <- fixture_lineage()
  altered$columns[[2]]$expression <- "AVG(amount)"
  new <- convert_lineage_to_graph(altered)

  expect_true(lineage_has_changes(lineage_diff(old, new)))
  expect_false(lineage_has_changes(lineage_diff(old, old)))
  expect_error(lineage_has_changes(list()), "lineage_diff")
})

test_that("diffing against an edge-free lineage adds no phantom rows", {
  # paste0() recycles zero-length inputs, so an empty edge frame used to
  # key as "." and fabricate an NA row on the other side of the diff
  old <- chain_graph()
  new <- chain_graph()
  new$edges <- list()

  diff <- lineage_diff(old, new)
  expect_identical(nrow(diff$added_edges), 0L)
  expect_identical(nrow(diff$removed_edges), 2L)

  rev <- lineage_diff(new, old)
  expect_identical(nrow(rev$removed_edges), 0L)
  expect_identical(nrow(rev$added_edges), 2L)
})

test_that("removed edges feeding downstream consumers are breaking", {
  old <- chain_graph()
  new <- chain_graph()
  new$edges <- new$edges[2] # drop a.x -> b.y, keep b.y -> c.z

  diff <- lineage_diff(old, new)
  expect_named(
    diff$removed_edges,
    c("source_table", "source_column", "target_table", "target_column", "severity")
  )
  expect_identical(diff$removed_edges$severity, "breaking")
})

test_that("changes to terminal target columns are breaking", {
  old <- api_fixture_graph()
  altered <- fixture_lineage()
  altered$columns[[2]]$expression <- "AVG(amount)"
  diff <- lineage_diff(old, convert_lineage_to_graph(altered))

  expect_identical(diff$changed_edges$severity, "breaking")
})

test_that("removing a dead intermediate column's edge is non-breaking", {
  old <- list(
    nodes = list(
      create_table_node("a", "x"),
      create_table_node("b", "tmp", table_type = "transform")
    ),
    edges = list(create_column_edge("a", "x", "b", "tmp"))
  )
  new <- old
  new$edges <- list()

  diff <- lineage_diff(old, new)
  expect_identical(diff$removed_edges$severity, "non-breaking")
})

test_that("pure additions are non-breaking", {
  old <- api_fixture_graph()
  new_lineage <- fixture_lineage()
  new_lineage$columns[[3]] <- list(
    output_name = "email",
    expression = "email",
    type = "identity",
    sources = list(list(table = "customers", column_name = "email"))
  )
  diff <- lineage_diff(old, convert_lineage_to_graph(new_lineage))

  expect_identical(unique(diff$added_edges$severity), "non-breaking")
  expect_identical(unique(diff$added_columns$severity), "non-breaking")
  expect_identical(nrow(diff$removed_edges), 0L)
})

test_that("removed columns are classified by their consumers", {
  # a source-free target column has no removed edge to carry the change
  old <- list(
    nodes = list(create_table_node("out", c("total", "note"), table_type = "target")),
    edges = list()
  )
  new <- list(
    nodes = list(create_table_node("out", "total", table_type = "target")),
    edges = list()
  )
  expect_identical(lineage_diff(old, new)$removed_columns$severity, "breaking")

  # an isolated source column nothing consumed
  old <- list(nodes = list(create_table_node("a", c("x", "unused"))), edges = list())
  new <- list(nodes = list(create_table_node("a", "x")), edges = list())
  expect_identical(lineage_diff(old, new)$removed_columns$severity, "non-breaking")
})
