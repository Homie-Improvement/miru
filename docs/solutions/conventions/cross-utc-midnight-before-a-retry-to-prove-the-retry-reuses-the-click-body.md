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
  - retries
  - idempotency
  - fake-timers
  - react-query
  - work-date
applies_when:
  - A test must prove that an automatic retry resends a request body built at the user's click, and the body holds a date taken from the current clock.
---

# Cross UTC midnight before a retry to prove the retry reuses the click's body

## Context

FloatingTimer's Save builds `work_date` from `new Date().toISOString()`. The body and the `Idempotency-Key` must be fixed when the user clicks. The retry must not rebuild them, or a lost response can record the same time twice under two keys or two dates. React Query retries a failed mutation once in this app, after a delay of about one second.

At an ordinary test time, a date rebuilt on retry is the same as the original date. An assertion that the retry body equals the first body then passes even if the code rebuilds the body. The test cannot see the bug.

## Solution

Make the clock a value that changes between the send and the retry.

1. Use fake timers. Set the system time just before UTC midnight, for example `2026-01-05T23:59:59.500Z`.
2. Mounting the component waits for its startup requests and moves the fake clock. Call `vi.setSystemTime` again right before the click.
3. Fail the first send. Advance time well past the retry delay with `vi.advanceTimersByTimeAsync` inside `act`.
4. Assert that the clock is now on the next day. Without that check, a later change to the delay could leave both sends on the same day, and the test would still pass.
5. Assert that the retry body deep-equals the first body, and that `work_date` is still the click's day.

Do not set a retry option in the test, and do not mock the key generator. Read keys from the request headers the adapter records. Otherwise the test checks its own settings, or a fixed mock key hides a key rebuilt on retry.

For the second-Save check, keep the body the same as the first save: the same timer at the same moment. Then only the click itself can explain a different key.

## Why it matters

An equality assertion only proves something when the value would differ under the bug. Crossing midnight turns a rebuilt date into a visible difference. The PR body reports that moving only the `work_date` computation into the mutation function made this test fail with `2026-01-06` against `2026-01-05`.

## Evidence

PR #443 adds `app/javascript/src/components/TimesheetEntries/__tests__/FloatingTimer.saveRetry.test.tsx`. It sets `CLICK_TIME` to `2026-01-05T23:59:59.500Z`, calls `vi.setSystemTime(CLICK_TIME)` again after `renderTimer` with a comment that the render advanced the clock, and advances `PAST_RETRY_DELAY_MS` (5000 ms). It asserts `new Date().toISOString().startsWith(CLICK_DAY)` is false, then checks key and body equality and `work_date: CLICK_DAY`. The adapter reads keys with `AxiosHeaders.from(config.headers).get("Idempotency-Key")`. The PR body records the failing `work_date` result from the temporary change.
