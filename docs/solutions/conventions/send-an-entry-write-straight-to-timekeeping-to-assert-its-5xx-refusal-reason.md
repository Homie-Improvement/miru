---
module: spec/integration/timekeeping
date: 2026-11-24
problem_type: convention
component: testing_framework
severity: low
audience: both
related_components:
  - timekeeping_reference_facts
  - entry_write_client
tags:
  - timekeeping
  - reference-unavailable
  - table-lock
  - live-specs
applies_when:
  - A spec must assert the reason field of a Timekeeping 5xx answer
  - A spec locks a table that Timekeeping::ReferenceFacts reads
---

# Send an entry write straight to Timekeeping to assert its 5xx refusal reason

## Context

The "Reference facts unavailable" case must show Timekeeping refusing an entry write with 503 and `{"reason": "reference_unavailable"}`. The monolith's timesheet entry API forwards writes to Timekeeping. But the monolith answers every Timekeeping 5xx with its own body, so the `reason` is gone by the time the test sees it.

The outage is made by holding `LOCK TABLE project_members IN ACCESS EXCLUSIVE MODE`, a table `Timekeeping::ReferenceFacts` reads. `Timekeeping::UserToken.mint` reads the same reference facts.

## Solution

- Mint the user token and build the body (`Timekeeping::EntryWriteClient.create_body`) before taking the lock. Under the lock, minting waits in the test process.
- POST the entry straight to Timekeeping's entries route with the user token, `Ownership-Generation`, and a fresh `Idempotency-Key`, as the monolith would.
- Set the client read timeout above `Timekeeping::ReferenceClient::TIMEOUT_SECONDS` (here `ENTRY_WRITE_READ_SECONDS = 10`), so Timekeeping answers before the test cuts the request off.
- Prove the monolith's reference request waits on the holder with `blocked_by?`, then read the response.
- Compare entry, receipt and projection counts with the counts taken before the write.

## Why it matters

An assertion through the monolith can show only that some error came back. It cannot tell a reference timeout from any other 5xx. Minting under the lock blocks the test itself, so no request ever reaches the server under test.

## Evidence

PR #617 adds `section_9_3_post_timekeeping_entry` and `ENTRY_WRITE_READ_SECONDS` to `spec/support/timekeeping/section_9_3_live.rb`; the helper's comment states the monolith answers every Timekeeping 5xx with its own body. The "Reference facts unavailable" example in `spec/integration/timekeeping/section_9_3_spec.rb` mints the token before `section_9_3_hold_project_members`, with a comment that minting reads the same reference facts. The pull request's test plan records that with the lock replaced by `SELECT 1` the request was not blocked and the write answered 201.
