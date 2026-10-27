---
module: timekeeping
date: 2026-10-27
problem_type: convention
component: observability
severity: medium
evidence_grounding: anchored
grounding_evidence: "PR #196 adds reconciliation_differences and event_counts_by_company in app/services/timekeeping/alert_signals.rb, filtering with IS DISTINCT FROM 'true' and casting company_id with Integer(..., exception: false) so bad values count under nil. Specs in spec/tasks/timekeeping_alerts_5_spec.rb and spec/tasks/timekeeping_alerts_5_2_spec.rb store rows without company_id or listed and expect a company_id=all alert."
audience: both
related_components:
  - rails_event_viewer
  - alerts
tags:
  - jsonb
  - event-history
  - alerts
  - null-handling
  - postgres
applies_when:
  - An alert counts rows whose payload is free-form JSON
  - A JSON flag excludes rows from an alert count
  - Alert counts are grouped by an id read out of JSON
---

# Count free-form JSON alert rows so missing fields still alert

## Context

Event history rows keep their data in a free-form JSON `payload`. Nothing guarantees that `payload -> 'data'` holds `company_id` or the `listed` flag. The alert reader in `Timekeeping::AlertSignals` must decide what to do with a row that lacks them.

The obvious queries drop such rows without a sound:

- `payload -> 'data' ->> 'listed' = 'false'` is not true when the key is missing, because the comparison is NULL.
- An integer cast of `company_id` that raises, or a filter on a non-null id, loses the row or crashes the run.

An alert reader that drops rows reads as healthy exactly when the data is wrong.

## Solution

Write the exclusion as the thing that explains a row, and let everything else count:

```ruby
.where("(payload -> 'data' ->> 'listed') IS DISTINCT FROM 'true'")
```

Group by the raw JSON text, then convert without raising, and count anything that is not an integer under no company:

```ruby
events.group(Arel.sql("payload -> 'data' ->> 'company_id'")).count
      .each_with_object(Hash.new(0)) { |(company_id, count), counts| counts[Integer(company_id, exception: false)] += count }
```

A nil company is printed as `company_id=all`, so the operator still sees the alert.

## Why it matters

For alerts, the safe failure is a noisy alert, not a missing one. Only an explicit `'true'` explains a reconciliation difference. Any other value, including a missing key, counts as unexplained. The same rule applies to any exclusion flag or grouping key read from JSON.

## Evidence

- PR #196, `app/services/timekeeping/alert_signals.rb`: `reconciliation_differences` uses the `IS DISTINCT FROM 'true'` filter, and `event_counts_by_company` groups by the JSON text and uses `Integer(company_id, exception: false)`. Comments state that a malformed row is never dropped.
- PR #196, `spec/tasks/timekeeping_alerts_5_spec.rb`: "alerts on a stored reconciliation event whose payload names no company under company_id=all without crashing".
- PR #196, `spec/tasks/timekeeping_alerts_5_2_spec.rb`: "alerts under company_id=all for a stored snapshot change event that names no company".
- PR #196, `spec/services/timekeeping/alert_signals_spec.rb`: "still alerts under no company for a stored reconciliation event whose payload lacks company_id and listed".
