---
module: timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: low
audience: both
related_components:
  - reports
  - timekeeping-projection
tags:
  - parity
  - ordering
  - pagination
  - cutover
applies_when:
  - A parity spec compares a reader whose ORDER BY does not include a unique column
  - The reader pages its results
---

# Sort tied rows by id, and fit one page, when comparing readers across cutover

## Context
At cutover, the projection rewrites the `timesheet_entries` rows. Postgres returns rows with equal sort keys in whatever order it reads them, and a rewrite can change that order. `Reports::TimeEntries::ReportService` orders by client and `work_date` only, and returns pages of 50. So after cutover, entries on the same date can come back in a new order, and a page boundary can fall in a different place among them. The data is the same, but the outputs differ.

## Solution
In the parity comparison:

- Choose a window that fits in one page. The spec reads only the last day that holds entries.
- In a normalizer, sort each list of tied rows by `id`, and do this for both reads.
- Do the same for any list the reader returns in no defined order, such as `Team::RemovalImpactService` `project_names` or each day's entries in `TimeTrackingIndexService`.

Normalize only the order. Never drop fields, so a real difference still fails.

## Why it matters
If you skip this, the parity test fails, or flakes, on a change in row order. Then someone "fixes" it by loosening the comparison, and real regressions get through. Fixing the window and sorting the ties keeps the strict comparison.

## Evidence
- PR #539 adds `spec/integration/timekeeping/extraction_scenarios_spec.rb`. The `Reports::TimeEntries::ReportService` row explains the ties and the 50-row page, reads a single day, and sorts each group's entries by `id` in its `normalize:` lambda.
- The `Team::RemovalImpactService` and `TimeTrackingIndexService` rows in the same file have `normalize:` lambdas that sort lists the readers leave unordered.
