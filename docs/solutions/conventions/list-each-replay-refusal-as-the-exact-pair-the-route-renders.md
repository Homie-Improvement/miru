---
module: timekeeping
date: 2026-11-23
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - live-handoff-specs
  - error-handler
tags:
  - refusal-table
  - replay-verdict
  - cross-company
  - byte-equality
applies_when:
  - Adding a pair to LiveHandoff::MONOLITH_REFUSALS or another refusal table
  - Proving a cross-company replay is refused on a monolith web route
---

# List each replay refusal as the exact pair the route renders

## Context

`LiveHandoff.replay_verdict` accepts a replay only when the reply equals the stored answer byte for byte, or matches one exact status and body pair in a refusal table. This strictness is the point: a loose match could hide a replay that wrote again. But it also means a missing or slightly wrong pair fails a correct refusal.

## Solution

- Copy each pair from the code that renders it. The monolith key-reused refusal is a 422 whose body has both `errors` and `"reason" => Timekeeping::Gateway::KEY_REUSED_REASON`. The older plain 422 pair has no `reason`, so it does not match it. `MONOLITH_REFUSALS` now holds both.
- Do not add a 404 to the same-company table. A 404 body carries the record's own not-found message, so it is not a fixed pair.
- For a cross-company replay, build one table for that case with `LiveHandoff.cross_company_web_refusals(not_found_message:)`. It adds one exact 404 pair to the monolith pairs. Get the message by running the same scoped find the controller runs, `company.projects.kept.find(...)`, with the same value type the controller receives. A form post sends the id as a string, so the request spec passes `other_project.id.to_s`. The spec also fails any reply equal to the other company's stored reply.
- For relay replays, compare bytes, not parsed JSON. The projection renders its stored answer with `render json:`, so the expected bytes are `receipt.response_body.to_json`. A parsed comparison accepts a reply whose whitespace or key order differs.

## Why it matters

When a real refusal fails the verdict, the tempting fix is to loosen the match, for example any 404 or any 422. That would let a replay that wrote again pass as long as its reply looked like an error. Exact pairs from the rendering code keep the proof strict and still accept every real refusal.

## Evidence

- PR #578, `spec/support/timekeeping/live_handoff.rb`: `MONOLITH_REFUSALS` gains the 422 pair with `"reason" => Timekeeping::Gateway::KEY_REUSED_REASON`; `cross_company_web_refusals(not_found_message:)` adds one 404 pair.
- PR #578, `spec/meta/timekeeping_live_handoff_spec.rb`: the key-reused 422 is refused on `MONOLITH_REFUSALS` and fails on `TIMEKEEPING_REFUSALS`; the cross-company table refuses only the exact message, and a 404 fails on the plain monolith table.
- PR #578, `spec/requests/api/v1/timesheet_entries/create_spec.rb`: builds the not-found message with `company.projects.kept.find(other_project.id.to_s)`. The PR records that this request example first failed and was fixed.
- PR #578, `spec/integration/timekeeping/late_replay_spec.rb`: the relay verdict compares `reply.body.b` with `receipt.response_body.to_json.b`.
