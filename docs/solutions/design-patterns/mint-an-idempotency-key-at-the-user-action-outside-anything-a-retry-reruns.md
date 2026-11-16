---
module: web time-entry writes
date: 2026-11-16
problem_type: design_pattern
component: frontend
severity: high
audience: both
related_components:
  - timesheetEntryApi
  - react-query
  - axios
tags:
  - idempotency-key
  - retry
  - axios-interceptor
  - react-query-mutation
  - duplicate-writes
applies_when:
  - Adding or changing a web call that writes time entries through timesheetEntryApi
  - Wrapping a write in a React Query mutation, which this app retries once automatically
  - One user action sends several write requests
---

# Create an Idempotency-Key at the user action, outside anything a retry runs again

## Context

The server replays a write whose `Idempotency-Key` header matches an answer it already stored. Replay means it sends back that stored answer instead of writing again. This only helps if every resend of one user action carries the same key.

The web app resends writes on its own in two places. The 401 session recovery in `app/javascript/src/apis/api.ts` sends the same request config again after a session check. The shared React Query client retries a failed mutation once, and each retry calls `mutationFn` again. A key created in either of those places is new on every resend. The server then treats the resend as a new action and writes a second entry.

## Solution

- Create the key with `newIdempotencyKey()` from `app/javascript/src/apis/idempotency.ts` at the start of the click or submit handler. Do not create it in a helper that a retry calls again.
- Put the header on that call's own axios config, through `idempotencyHeaders(key)`, and not in the request interceptor. The 401 recovery resends the config unchanged, so a header on the config is sent again as it was. An interceptor would make a new key on the resend.
- For a React Query mutation, build both the body and the key in the handler and pass them to `mutate(...)` as variables. React Query passes the same variables to every attempt. `FloatingTimer.tsx` used to build the body inside `mutationFn`, including `new Date()` for `work_date`. A retry after midnight would then send a new body under the old key, and the server refuses a reused key that comes with a different body. `saveTimerEntry.ts` now receives `{ entry, userId, idempotencyKey }` fully built.
- When one action sends several writes, give each request its own key. In the copy-last-week action, one key shared by N creates would make the server replay the first create, or refuse the others as a reused key, and those entries would be lost. `createEntriesWithOwnKeys.ts` calls `newIdempotencyKey()` once per entry.
- Make the key a required parameter with a branded type (`IdempotencyKey`). An old caller that still passes a user id in that position then fails to compile. The Vite build and `pnpm lint` do not check types, so run the TypeScript compiler to catch it.

A user who clicks Save again after an error makes a new action with a new key. This pattern does not merge a double click into one write.

## Why it matters

Each wrong placement passes a normal save. The duplicate shows up only when a response is lost and the client resends, and then a user's time is recorded twice. A test that builds its own key never runs into the problem. To catch a regression, the test must drive the real retry path: a scripted adapter that answers 401 then 200, or fails once and then succeeds. It must then check that both sends carry the same key and body.

## Evidence

- PR #337 adds `app/javascript/src/apis/idempotency.ts`. Its comments say the header goes on the request's own config because the 401 recovery resends that config unchanged, and that a key must be made when the action starts so every resend carries it.
- PR #337 changes every write in `timesheetEntryApi` in `app/javascript/src/apis/api.ts` (create, update, destroy, destroyBulk, updateBulk) to take a required `IdempotencyKey` and pass it as `headers: idempotencyHeaders(idempotencyKey)`.
- `app/javascript/src/components/TimesheetEntries/FloatingTimer.tsx` now builds the entry and key in `handleSaveEntry` and calls `saveTimerMutation.mutate({ entry, userId, idempotencyKey })`. `app/javascript/src/components/TimesheetEntries/saveTimerEntry.ts` explains that React Query passes the same variables to every attempt.
- `app/javascript/src/components/TimeTracking/createEntriesWithOwnKeys.ts` gives each copied entry its own key. Its comment explains that a shared key would lose the later entries.
- Tests in this pull request: `app/javascript/src/apis/__tests__/timesheetEntryApi.test.ts` checks that a create answered 401 then 200 is sent twice with the same UUID v4 key. `app/javascript/src/components/TimesheetEntries/__tests__/saveTimerEntry.test.ts` checks that a timer save retried after a network error resends the same key and body. `app/javascript/src/components/TimeTracking/__tests__/createEntriesWithOwnKeys.test.ts` checks that three copied entries send three different keys.
- The pull request body reports that `pnpm test:js` passed 8 tests.
