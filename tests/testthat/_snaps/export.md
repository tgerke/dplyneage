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

# lineage_mermaid renders subgraphs, edges, and classes

    Code
      cat(lineage_mermaid(lineage))
    Output
      flowchart LR
        subgraph orders["orders"]
          orders_customer_id["customer_id"]
          orders_amount["amount"]
        end
        subgraph output["output"]
          output_customer_id["customer_id"]
          output_total["total"]
        end
        orders_customer_id --> output_customer_id
        orders_amount -->|"sum(amount, na.rm = TRUE)"| output_total
        classDef source fill:#f0f7ff,stroke:#3b82f6,color:#1d4ed8
        classDef transform fill:#fef3f2,stroke:#f59e0b,color:#d97706
        classDef target fill:#f0fdf4,stroke:#10b981,color:#059669
        class orders source
        class output target

