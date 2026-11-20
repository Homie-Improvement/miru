---
module: TimesheetEntries
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - FloatingTimer
  - queryClient
tags:
  - regression-tests
  - mutation-testing
  - retries
  - idempotency
applies_when:
  - A test protects several independent behaviors, and temporary code changes are used to verify its assertions.
---

# Verify independent regression checks separately

## Context

A failing test does not prove that every assertion detects its intended regression. If two defects are introduced together, either defect can cause the failure and leave the other check untested.

FloatingTimer needs two retry guarantees: the request keeps its original idempotency key and its original body. The test must detect moving either key creation or date creation into the function that a retry runs again.

## Solution

Introduce each known-bad change separately. Start from the passing implementation before each check, and confirm that the failure identifies the intended defect.

For the timer test:

1. Move only `newIdempotencyKey()` into the mutation function. Confirm that key equality fails, then restore the implementation.
2. Move only the `work_date` computation into that function. Confirm that body equality fails across UTC midnight, then restore the implementation.

Keep the other behavior correct during each check. A run with both changes costs less execution time, but cannot establish that both checks work independently.

## Why it matters

The key assertion can fail before the test reaches the body assertion. A combined check can therefore pass its verification goal while leaving date regeneration undetected. Separate checks establish which regression each assertion detects, without committing defective production code.

Use this approach when a test protects independent behaviors. The presence of several assertions alone does not establish their sensitivity.

## Evidence

PR #443 adds `app/javascript/src/components/TimesheetEntries/__tests__/FloatingTimer.saveRetry.test.tsx`. The test compares retry keys before comparing request bodies and checks that `work_date` remains `2026-01-05` after the clock advances across midnight.

The test plan in PR #443 records two separate temporary changes. Moving only key creation failed the key-equality assertion. Moving only date creation failed the body assertion. The description reports restoring the production file after each check; the diff adds only the test file.
