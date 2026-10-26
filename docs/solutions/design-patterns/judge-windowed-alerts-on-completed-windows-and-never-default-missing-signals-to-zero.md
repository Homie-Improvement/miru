---
module: timekeeping
date: 2026-10-26
problem_type: design_pattern
component: observability
severity: medium
evidence_grounding: anchored
grounding_evidence: "app/services/timekeeping/alerts.rb in PR #121 has completed_windows/completed_recently? and treats a nil signal as no measurement; app/services/timekeeping/alert_signals.rb lists sourceless signals in unavailable; app/services/timekeeping/metrics_client.rb checks REQUIRED_FIELDS types; spec/services/timekeeping/alerts_spec.rb covers the partial-window cases."
audience: both
related_components:
  - metrics_client
  - alert_signals
  - write_metrics
tags:
  - alerting
  - metrics-windows
  - percentiles
  - fail-safe
applies_when:
  - Evaluating an alert worded 'for N minutes' over fixed metric windows
  - An alert task combines local records with a remote metrics read
---

# Judge windowed alerts on completed windows, and never default missing signals to zero

## Context

Timekeeping counts writes per company in fixed 300-second windows. The `timekeeping:alerts` task turns these counts and the monolith's records into section 11.3 alerts. An example rule: `503 reference_unavailable` over 1% of writes for 5 minutes.

Review of the plan for PR #121 found three ways a natural first design goes wrong:

- Judging the newest window fires on one failure seconds after a window opens. It also lets one healthy write in a new window hide a whole failed window before it.
- A signal with no source, set to zero, reads as healthy.
- A metrics body of the wrong shape, for example one without `window_seconds` from an older service, crashes evaluation. It then takes the monolith-side alerts down with it.

## Solution

- **Completed windows only.** For each company, judge its latest window whose end (`window_start + window_seconds`) is at or before `now` and after `now - window_seconds`. Read `window_seconds`, the bucket bounds and the overflow key from the metrics body. Do not keep copies in the monolith.
- **Per company.** Never pool companies. One failing company is hidden by a large healthy one.
- **Overflow counts as over every bound.** When only the overflow bucket reaches 95%, the p95 is `Float::INFINITY`, so it exceeds 300 ms.
- **Rate denominator.** Divide by `writes + reference_unavailable`, because Timekeeping counts a refused write only under `reference_unavailable`.
- **Missing means unavailable.** The gatherer leaves sourceless signals out and lists them in `unavailable`. The evaluator raises nothing for an absent key. The task prints one `unavailable` line for each.
- **Validate at the boundary.** `MetricsClient` checks each required field's type, such as `"companies" => Array`, and raises its own `Error` for a bad body or a garbled response. The gatherer turns that error into `metrics_error`. The task prints the alerts it could evaluate, then exits non-zero.

The cost of completed windows: an alert can arrive up to one window length after failures begin. That is the reading of "for 5 minutes" this change chose.

## Why it matters

Each wrong choice either pages someone for a blip or hides a real outage. None of them shows up in tests that feed only steady, well-formed data. Tests should include a failure in a window still in progress, a healthy write after a failed window, an overflow-only window, and a body with a null or missing field.

## Evidence

- PR #121 adds `app/services/timekeeping/alerts.rb` with `completed_windows`, `completed_recently?`, `reference_unavailable_rate` and `p95_bound` returning `Float::INFINITY` for overflow.
- PR #121 adds `app/services/timekeeping/alert_signals.rb` with `NO_SOURCE`, the `unavailable` list and the `metrics_error` rescue of `MetricsClient::Error`.
- PR #121 adds `app/services/timekeeping/metrics_client.rb` with `REQUIRED_FIELDS` type checks and `Net::HTTPBadResponse` in the rescue list. `spec/services/timekeeping/metrics_client_spec.rb` covers a body without `window_seconds` and one with `"companies" => nil`.
- `spec/services/timekeeping/alerts_spec.rb` covers a healthy newer partial window that neither hides a failed completed window nor fires on its own. `spec/tasks/timekeeping_alerts_spec.rb` shows the pending-intent alert still printing before a non-zero exit when the metrics read fails.
- PR #121 adds `window_seconds` to `timekeeping/app/presenters/timekeeping/write_metrics_presenter.rb`.
