---
module: timekeeping gateway specs
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: speculative
audience: both
related_components:
  - spec/support/timekeeping/forwarded_timekeeping_helpers.rb
  - Timekeeping::Gateway
  - MCP write tools
tags:
  - rspec
  - shared-setup
  - timekeeping
  - legacy-store
  - spec-refactor
applies_when:
  - Merging copied examples in a Timekeeping gateway spec onto one shared setup
  - Reusing with_forwarded_timekeeping_env or arrange_forwarded_timekeeping in a spec that checks local TimesheetEntry rows
---

# Choose a gateway spec's shared setup by the store its assertions read

## Context

The entry gateway sends each time-entry write to one of two stores. While the legacy store owns entries, a write leaves a local `TimesheetEntry` row. While Timekeeping owns them, the write goes to the Timekeeping service, which specs replace with `TimekeepingContract::FakeTimekeeping`, and no local row appears.

The spec helpers `with_forwarded_timekeeping_env` and `arrange_forwarded_timekeeping` set up the second case. They do more than register users and projects on the fake: they also make Timekeeping the owner. That makes them look like the natural shared setup for every gateway spec, but they change which store a write lands in.

The MCP write-tools spec checks local rows, for example that a retry after a handoff takes `TimesheetEntry.where(user:).count` from 1 to 2. Under the forwarding setup that count would never move. The test would then fail, or someone would "fix" it by checking the fake, which drops the only coverage that the MCP path writes a local row.

## Solution

Before you put a setup in a shared `before` or `around`, read what the examples assert and pick the setup that puts writes where those assertions look:

- Examples that check the fake's requests, stored entries or outbox (the agent and CLI forwarded cases) use the forwarding helpers.
- Examples that check local `TimesheetEntry` rows (the MCP write-tools spec) keep the legacy-store setup, with no forwarding helper. Say so in a comment at the top of the file.
- A handoff refusal that happens before any store is chosen needs neither. Keep it in a context outside the forwarding `around`, acting on a local legacy row, and say why in a comment.

When one file needs both, scope the forwarding helpers to a nested context, not the top-level describe. The CLI spec in this change does this with `context "with Timekeeping owning the entries"` beside a separate `context "during a handoff"`.

## Why it matters

A spec cleanup is supposed to change no coverage. Moving a setup into a shared block hides its side effects from anyone reading the examples. If the setup changes the owning store, the merged examples test a different code path than the copies they replace. That gap only shows up as a failing local-row check, or not at all if the check is rewritten to fit.

## Evidence

- PR #247 rewrites `spec/mcp/tools/write_tools_gateway_spec.rb` on a single setup that does not call the forwarding helpers. It adds the top comment "The entries stay in the legacy store here, so a write that gets through the gateway leaves a local row." The merged example keeps its local-row checks: `change { TimesheetEntry.where(user:).count }.from(1).to(2)` on the retry, and no change on a second retry.
- In the same PR, `spec/requests/api/v1/agent/timesheet_entries/gateway_spec.rb` uses `with_forwarded_timekeeping_env` and `arrange_forwarded_timekeeping` at the top level, because its examples check `fake.requests`, `fake.stored_entry` and `fake.outbox`.
- In `spec/requests/api/v1/cli/timesheet_entries/gateway_spec.rb`, the forwarding helpers sit only inside `context "with Timekeeping owning the entries"`. The handoff case sits in `context "during a handoff"` with the comment "No Timekeeping is configured here: the refusal comes before any store is chosen, and the update and destroy act on a local legacy row."
- A review finding on PR #247's plan reported that `arrange_forwarded_timekeeping` sets the owner to `timekeeping` and that the gateway then forwards creates and returns an unsaved entry instead of a local row. The plan was changed so that only the agent and CLI files use forwarding. The helper and gateway source are not part of this change. To confirm, read `spec/support/timekeeping/forwarded_timekeeping_helpers.rb` and the `:timekeeping` branch of `Timekeeping::Gateway#create`.
