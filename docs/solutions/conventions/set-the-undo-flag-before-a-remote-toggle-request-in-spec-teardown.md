---
module: timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping-test-hooks
  - relay
tags:
  - teardown
  - relay-pause
  - lost-reply
  - ensure
applies_when:
  - A spec toggles persistent state on another process over HTTP, such as /internal/v1/test-hooks/relay/pause, and must undo it in ensure
---

# Set the undo flag before a remote toggle request in spec teardown

## Context
The live specs pause the Timekeeping relay with `POST /internal/v1/test-hooks/relay/pause`. A pause that is never undone holds back every snapshot in the next examples. If the spec sets its "paused" flag only after the request returns, there is a gap. The server can apply the pause and then lose its reply. The request raises, the flag stays false, and the `ensure` path skips the resume.

## Solution
Set the flag first, then send the request. Make sure the undo is safe to run when the toggle never took effect. In `spec/integration/timekeeping/extraction_scenarios_spec.rb`, `extraction_pause_relay!` sets `@extraction_relay_paused = true` before it calls `extraction_relay_hook("pause")`. `extraction_with_runtime` resumes in its `ensure` when the flag is set. Resuming a relay that is not paused only removes a file that is not there.

## Why it matters
The failure happens only when a reply is lost, so normal runs never show it. When it does happen, its effect shows up in later examples, which are hard to trace back to the cause. Recording intent before the side effect, with an undo that is safe to repeat, closes the gap for free.

## Evidence
- PR #539 adds `spec/integration/timekeeping/extraction_scenarios_spec.rb`. The comment on `extraction_pause_relay!` says the flag is set first so that a pause whose answer was lost is still resumed by teardown, and that resuming an unpaused relay only removes a file that is not there.
- In the same file, `extraction_with_runtime` calls `extraction_resume_relay! if @extraction_relay_paused` in its `ensure`.
- The code review on PR #539 asked for this order, and the author fixed it in this diff. The author did not inject a lost-reply failure to test it.
