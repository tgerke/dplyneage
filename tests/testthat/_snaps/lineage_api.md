# print method summarises the lineage

    Code
      print(api_fixture_graph())
    Output
      <dplyneage lineage>
        engine: sqlglot (dialect: duckdb)
        sources: customers, orders
        output: customer_id, total_spent
        2 column edges

# lineage_diff reports added and removed edges and columns

    Code
      print(diff)
    Output
      <dplyneage lineage diff>
      Added edges:
        + customers.email -> output.email
      Removed edges:
        - orders.amount -> output.total_spent
      Added columns:
        + customers.email
        + output.email
      Removed columns:
        - orders.amount
        - output.total_spent

# identical lineages diff to no changes

    Code
      print(diff)
    Output
      No lineage changes.

