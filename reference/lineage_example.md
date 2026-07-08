# A built-in example lineage diagram

Renders a small customers/orders lineage diagram built with the manual
helpers. Handy for checking that the visualization works in your
environment, and as a template for building diagrams by hand.

## Usage

``` r
lineage_example()
```

## Value

A
[`lineage_flow()`](https://tgerke.github.io/dplyneage/reference/lineage_flow.md)
htmlwidget

## See also

Other manual lineage builders:
[`create_column_edge()`](https://tgerke.github.io/dplyneage/reference/create_column_edge.md),
[`create_table_node()`](https://tgerke.github.io/dplyneage/reference/create_table_node.md)

## Examples

``` r
lineage_example()

{"x":{"nodes":[{"id":"customers","type":"tableNode","data":{"label":"customers","columns":["customer_id","name","email","signup_date"],"tableType":"source","colors":{"bg":"#f0f7ff","border":"#3b82f6","header":"#1d4ed8"}},"position":{"x":0,"y":50},"draggable":true,"sourcePosition":"right","targetPosition":"left"},{"id":"orders","type":"tableNode","data":{"label":"orders","columns":["order_id","customer_id","order_date","total_amount"],"tableType":"source","colors":{"bg":"#f0f7ff","border":"#3b82f6","header":"#1d4ed8"}},"position":{"x":0,"y":300},"draggable":true,"sourcePosition":"right","targetPosition":"left"},{"id":"customer_summary","type":"tableNode","data":{"label":"customer_summary","columns":["customer_id","customer_name","email","first_order","total_spent"],"tableType":"target","colors":{"bg":"#f0fdf4","border":"#10b981","header":"#059669"}},"position":{"x":500,"y":150},"draggable":true,"sourcePosition":"right","targetPosition":"left"}],"edges":[{"id":"e_customers.customer_id_to_customer_summary.customer_id","source":"customers","target":"customer_summary","sourceHandle":"customer_id","targetHandle":"customer_id","animated":false,"style":{"stroke":"#64748b","strokeWidth":2}},{"id":"e_customers.name_to_customer_summary.customer_name","source":"customers","target":"customer_summary","sourceHandle":"name","targetHandle":"customer_name","animated":false,"style":{"stroke":"#64748b","strokeWidth":2}},{"id":"e_customers.email_to_customer_summary.email","source":"customers","target":"customer_summary","sourceHandle":"email","targetHandle":"email","animated":false,"style":{"stroke":"#64748b","strokeWidth":2}},{"id":"e_orders.order_date_to_customer_summary.first_order","source":"orders","target":"customer_summary","sourceHandle":"order_date","targetHandle":"first_order","animated":true,"style":{"stroke":"#64748b","strokeWidth":2},"label":"MIN()","labelStyle":{"fill":"#64748b","fontWeight":500,"fontSize":11},"labelBgStyle":{"fill":"#ffffff","fillOpacity":0.9}},{"id":"e_orders.total_amount_to_customer_summary.total_spent","source":"orders","target":"customer_summary","sourceHandle":"total_amount","targetHandle":"total_spent","animated":true,"style":{"stroke":"#64748b","strokeWidth":2},"label":"SUM()","labelStyle":{"fill":"#64748b","fontWeight":500,"fontSize":11},"labelBgStyle":{"fill":"#ffffff","fillOpacity":0.9}}]},"evals":[],"jsHooks":[]}
```
