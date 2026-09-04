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

# lineage_from_json rejects documents it cannot read

    Code
      lineage_from_json("{}")
    Condition
      Error:
      ! Not a lineage_json() document: it has no `format_version`.

---

    Code
      lineage_from_json("{\"format_version\": 2, \"nodes\": [], \"edges\": []}")
    Condition
      Error:
      ! This document has format_version 2; this version of dplyneage reads format_version 1. Update dplyneage to read it.

---

    Code
      lineage_from_json(
        "{\"format_version\": 1, \"nodes\": [{\"id\": \"t\"}], \"edges\": []}")
    Condition
      Error:
      ! Not a lineage_json() document: node 1 has no `type`.

---

    Code
      lineage_from_json("no-such-lineage.json")
    Condition
      Error:
      ! `x` must be a JSON document from lineage_json(), or the path to a file it wrote; 'no-such-lineage.json' is neither.

