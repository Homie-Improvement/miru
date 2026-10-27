---
module: timekeeping/spec/requests
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "timekeeping/spec/requests/internal/v1/write_delay_hook_spec.rb in PR #192 replaces three posts with one final write_delay_seconds check by a loop that asserts write_delay_seconds is 0.0 after each refused request, copied from the deleted write_delay_hook_2_spec.rb; the added comment says the delay persists in a file."
audience: both
related_components:
  - Timekeeping::TestHooks
tags:
  - spec-consolidation
  - refused-requests
  - persistent-state
applies_when:
  - Merging two examples that send the same sequence of refused requests
  - The state under test survives between requests, for example in a file or database row
---

# Check persistent state after each refused request when merging examples

## Context

PR #192 deleted `timekeeping/spec/requests/internal/v1/write_delay_hook_2_spec.rb` as a duplicate of `write_delay_hook_spec.rb`. Both sent the same three refused requests to `POST /internal/v1/test-hooks/writes/delay`: no credential, a user token, and a wrong service token. Both expected 401 every time.

They differed in one place. The numbered copy checked `Timekeeping::TestHooks.write_delay_seconds` after every request. The kept copy checked it once, after all three. Plan review caught that the copies were not equivalent.

## Solution

Before deleting the numbered copy, move its per-request check into the kept example. In PR #192 the kept example now loops over the three credentials and asserts both the 401 response and a zero delay inside the loop. A comment explains why: the delay persists in a file.

The general rule: when two copies look the same, compare where each assertion runs, not just what it asserts. Keep the copy, or merge in the assertions, that checks state at the most points.

## Why it matters

The delay survives between requests. A single check at the end only proves the final state. A bug where the first refusal sets a delay and a later refusal clears it would pass the end check. It would still slow real writes for the time between those requests. Deleting the stronger copy removes that coverage, and no test fails to tell you.

## Evidence

- PR #192 deletes `timekeeping/spec/requests/internal/v1/write_delay_hook_2_spec.rb`, whose loop asserted `write_delay_seconds.to_f` is `0.0` after each post.
- PR #192 changes `timekeeping/spec/requests/internal/v1/write_delay_hook_spec.rb`. Three separate posts with one final delay check become a loop with the delay check inside it.
- `spec/meta/timekeeping_alerts_specs_spec.rb` in PR #192 asserts that the kept file checks the delay inside an `.each` loop and includes the wrong-service-token credential.
