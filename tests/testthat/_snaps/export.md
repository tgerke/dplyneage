# exporters reject objects without nodes and edges

    Code
      lineage_json(list())
    Condition
      Error:
      ! `lineage` must be the result of extract_lineage(), or a list with `nodes` and `edges` built with create_table_node() and create_column_edge()

---

    Code
      lineage_graphml(mtcars)
    Condition
      Error:
      ! `lineage` must be the result of extract_lineage(), or a list with `nodes` and `edges` built with create_table_node() and create_column_edge()

