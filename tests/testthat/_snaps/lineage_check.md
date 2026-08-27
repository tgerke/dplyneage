# breaking changes fail with a classed condition carrying the diff

    Code
      lineage_check(check_old(), new, annotate = FALSE)
    Output
        breaking: removed edge orders.amount -> out.total
    Condition
      Error:
      ! Lineage check failed: 1 breaking lineage change (1 total). Inspect with lineage_diff(old, new); fail_on = "none" reports without failing.

# fail_on = 'none' reports without failing

    Code
      diff <- lineage_check(check_old(), new, fail_on = "none", annotate = FALSE)
    Output
        breaking: removed edge orders.amount -> out.total
      Lineage check passed: 1 change, 1 breaking.

# annotations mark findings by whether they fail the check

    Code
      lineage_check(check_old(), removed, annotate = TRUE)
    Output
      ::error::lineage: removed edge orders.amount -> out.total
    Condition
      Error:
      ! Lineage check failed: 1 breaking lineage change (1 total). Inspect with lineage_diff(old, new); fail_on = "none" reports without failing.

# annotation lines escape workflow-command characters

    Code
      lineage_check(old, new, annotate = TRUE)
    Output
      ::error::lineage: removed edge orders.amount -> out.share%25
    Condition
      Error:
      ! Lineage check failed: 1 breaking lineage change (1 total). Inspect with lineage_diff(old, new); fail_on = "none" reports without failing.

