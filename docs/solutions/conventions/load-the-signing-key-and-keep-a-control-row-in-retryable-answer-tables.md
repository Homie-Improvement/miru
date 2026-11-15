---
module: timekeeping
date: 2026-11-15
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - service_layer
tags:
  - table-driven-specs
  - reservation-client
  - service-token
  - vacuous-pass
applies_when:
  - Writing a spec table whose rows all expect Timekeeping::ReservationClient to answer retryable
  - Folding answer cases from several examples into one prepare or mark_billed table
---

# Load the signing key and keep a control row in retryable answer tables

## Context

`Timekeeping::ReservationClient` maps each service answer to an outcome. Anything outside its mapping table becomes `retryable`. Specs check this with a table of bad answers, each expected to give `retryable`.

The client also answers `retryable` for a reason unrelated to the answer. It mints a per-company service token before it sends anything. If the private key in `Timekeeping::UserToken::PRIVATE_KEY_ENV` is not loadable, the mint fails and the client answers retryable without sending a request. A separate example in the same spec covers that case.

So a table of "bad answer gives retryable" rows passes in full when the key is missing, even if the answer mapping is broken.

## Solution

Every table of answers that expect `retryable` must have three guards:

1. An `around` hook that sets `Timekeeping::UserToken::PRIVATE_KEY_ENV` to a real key. That way the client reaches the answer.
2. Checks beyond the state in each row: `expect(outcome.reason).to be_nil`, plus `conflicts` equal to `[]` for prepare or `counts` equal to `{}` for mark_billed. These checks pin the shape of the outcome as well as its name.
3. A well-formed control row that must not be retryable. For prepare, use a 409 conflict with `entry_id` that maps to `refused` with its conflicts. For mark_billed, use `[200, { "billed" => 1 }]` that maps to `committed` with `{ billed: 1 }`. If the client fell back to retryable for everything, only this row would fail.

Generate each row as its own `it`, so one failing row does not hide the others.

## Why it matters

The failure mode is silent. A missing environment value, a changed credential default or a broken key turns the whole table green. The control row and the per-row `reason`/`conflicts`/`counts` checks are the only parts that tell "mapped to retryable" apart from "never got that far".

## Evidence

PR #321 changes `spec/services/timekeeping/reservation_client_spec.rb`. Its new describe, "answers outside the mapping table", sets the key in an `around` hook. The hook's comment says that without a loadable key "every row would be retryable for the wrong reason". Each prepare row asserts `outcome.reason` is nil and `outcome.conflicts` is `[]`. Each mark_billed row asserts `outcome.counts` is `{}`. Each table ends with a well-formed example commented "so the rows above are not retryable only by default": "a well-formed 409 conflict is refused with its conflicts" and "a 200 with an integer billed count is committed with that count". The same file keeps the example "a prepare whose service token cannot be minted answers retryable and sends no request", which shows the mint-failure path that also answers retryable.
