---
module: timekeeping
date: 2026-11-15
problem_type: design_pattern
component: timekeeping_gateway
severity: high
audience: both
related_components:
  - timesheet_entry_controller
  - cli_timesheet_entries_controller
  - timesheet_entry_policy
tags:
  - idempotency
  - replay
  - authorization
  - pundit
  - prepared-store
applies_when:
  - A write path replays a stored idempotency answer before running the policy for a fresh write
  - The first write can change the row so that the edit policy now refuses it, for example by marking it billed
---

# Authorize a replayed update with read permission, not the edit policy

## Context

An idempotency key lets a client retry a request whose answer it lost. The server finds the stored answer, called a receipt, and returns it instead of writing again. To make that work, the receipt must be read before any check whose answer the first write can change.

The edit policy is such a check. `TimesheetEntryPolicy#update?` refuses a billed entry. So a PATCH that sets `bill_status: "billed"` commits, and its identical retry would fail with `Pundit::NotAuthorizedError` if the policy ran first. In the prepared store, the gateway now reads the receipt first. That raises a second question: what permission does the replay itself need?

## Solution

Give the replay its own authorization step. Do not drop authorization, and do not reuse the edit policy.

- `Timekeeping::Gateway#update` takes `authorize:` for fresh writes and `authorize_replay:` for replays. `authorize_replay` defaults to `authorize` for callers that grant no separate permission.
- A replayed answer first passes the lookup's company, id and scope checks (`EntryLookup.replayed`), then `authorize_replay`.
- The web and CLI controllers pass `authorize_replayed_entry`, which calls `authorize(entry, :show?)`. Permission to read back a committed answer is read permission.
- A fresh edit of the now-billed row still runs `authorize` and is still refused.

## Why it matters

There are two easy mistakes. Keeping the edit policy before the replay turns a committed write into a reported failure. The client then retries forever or shows an error for work that happened. Skipping authorization on the replay path returns stored entries with no access check. It also leaves the controller action with no `authorize` call, so a check that verifies an authorization happened can fail the request. A separate read-back permission avoids both mistakes.

## Evidence

- PR #319, `app/services/timekeeping/gateway.rb`: `update` gains `authorize_replay: authorize`. In the prepared store, `replay_local` runs before `find_authorized`, and `replayed_update` calls `EntryLookup.replayed` and then `authorize_replay`.
- PR #319, `app/controllers/api/v1/timesheet_entry_controller.rb` and `app/controllers/api/v1/cli/timesheet_entries_controller.rb`: both add `authorize_replayed_entry`, which calls `authorize(entry, :show?)`. Their comment states that the edit policy may refuse the entry the edit made, such as a billed one.
- PR #319, `spec/services/timekeeping/gateway_spec.rb`: the example "replays a committed prepared update to billed although the policy now refuses editing the entry" checks that the retry returns the first answer with no new rows, and that a fresh keyed edit of the billed row still raises `Pundit::NotAuthorizedError`.
- PR #319, `spec/requests/api/v1/timesheet_entries/gateway_spec.rb`: the examples "replays a committed unbilled/billed prepared update retried with the same key, writing nothing more" run the replay through the controller and expect 200 with unchanged row counts.
