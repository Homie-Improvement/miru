---
module: spec/support/timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/integration/timekeeping
tags:
  - rspec-pending
  - teardown
  - after-context
  - live-specs
applies_when:
  - A shared spec helper runs teardown steps that restore shared state, such as ENV, rebuilt integrations or a pause file
  - An example that uses that helper is marked pending
---

# Check teardown failures in an after(:context) hook when examples may be pending

## Context

RSpec still runs the body of a `pending` example. It reports that example as pending when the body fails, and it fails the example only if the body passes. Any failure after the `pending` call counts as the expected failure. The comment above `assert_clean_teardowns!` says this means a teardown failure in a pending example would pass silently.

The live relay-paused spec had an AC5 example that was pending, because the draft invoice save answered 422 until a follow-up invoice change landed. That change has since landed and the example is no longer pending, but the teardown rule below still applies to any pending example that uses the helper. Its teardown resumes the relay, restores ENV and reloads `config/initializers/timekeeping_handoff.rb` to rebuild the shared handoff integrations. If that rebuild raised, the example would still read as pending. Later examples would then inherit integrations that still point at the stopped runtime's URL and token.

## Solution

For teardown that guards shared state, record each failure on the example and check those records again outside the example:

- Each teardown step rescues its own error and appends `"name: Class: message"` to the example's metadata under `TimekeepingLiveHandoff::TEARDOWN_FAILURES_KEY`. Later steps still run.
- The per-example `after` hook also records a surviving pause file before it asserts that the file is gone.
- The shared context registers `after(:context) { TimekeepingLiveHandoff.assert_clean_teardowns!(self.class.descendant_filtered_examples.map(&:metadata)) }`. RSpec reports a failure there outside any example, so the run fails whether or not the examples are pending.
- When the body raised, its exception still propagates unchanged, so the real cause stays visible. When the body finished, the collected step errors are raised as one `TeardownFailed`.

The per-example check stays as well, so it still fails a normal example directly.

## Why it matters

`pending` is the right tool for an example that should turn red once a planned fix lands. But it also mutes every failure after the `pending` call, and teardown is part of that. Without a check at the group level, a cleanup defect in a pending example cannot fail the suite. The broken shared state then shows up later, in an unrelated example.

## Evidence

- PR #536 adds `spec/support/timekeeping/live_handoff_helpers.rb`. There, `run_steps` appends each step error to the failures list, and `run_with_teardown` raises `TeardownFailed` only when the body finished. The comment above `assert_clean_teardowns!` explains why the hook runs in `after(:context)`. The shared context `"timekeeping live handoff"` registers that hook and the pause-file `after` hook.
- When PR #536 landed, `spec/integration/timekeeping/relay_paused_spec.rb` called `pending relay_paused_ac5_pending_reason` inside `with_live_handoff`, after the pre-save checks. A later change removed that call and its helper once the draft invoice save stopped answering 422.
- `spec/meta/timekeeping_live_handoff_helpers_spec.rb` has the example "keeps the body's exception when the rebuild also raises, and records the rebuild failure for the group check". It shows that the body's error propagates, that the rebuild failure is recorded, and that `assert_clean_teardowns!` raises on that record.
- Limit: that spec passes built metadata to `assert_clean_teardowns!`. It does not run a real pending example through the shared context. Recommended verification step, not yet run: an isolated RSpec run with a pending body and a failing rebuild should exit non-zero.
