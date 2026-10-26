---
module: invoices
date: 2026-10-26
problem_type: convention
component: service_layer
severity: medium
evidence_grounding: speculative
audience: both
related_components:
  - reservation_port
tags:
  - data-define
  - immutability
  - value-objects
  - ruby
applies_when:
  - Defining a value type with Data.define that holds arrays, hashes or strings
  - A value is stored and later resent, or read by more than one part of the code
---

# Copy and freeze nested inputs in Data.define value types

## Context

Ruby's `Data.define` freezes the record. It does not freeze the objects the record points to. An array, hash or string passed into the constructor is the caller's own object. The caller can change it after the value is built, and the change shows through the value.

This matters for the reservation port. `Invoices::ReservationRequest` is stored on the intent row so that a retry resends the same request. `Invoices::ReservationOutcome` is read by more than one caller. If either could change after it was built, a retry or a second reader would see different data.

## Solution

In the constructor, build new frozen copies of every nested value, then pass them to `super`. Do not call `freeze` on the caller's object, because that breaks a caller that still owns and uses it.

- `ReservationRequest` turns entries into a new canonical array: `Array(entries).map { |entry_id| Integer(entry_id) }.uniq.sort.freeze`. It stores `operation_id.dup.freeze` and `disposition.dup.freeze`.
- `ReservationOutcome` has a recursive `frozen_copy`. It rebuilds hashes and arrays and calls `value.dup.freeze` on leaf values. It also rebuilds each conflict as a fresh `{ entry_id:, reason: }` hash.
- Both constructors check their input, such as a missing `company_id` or an unknown state, before calling `super`.

One canonical form for entries (unique Integers, in ascending order) also means two requests for the same set compare as equal, and the stored request has one exact form.

## Why it matters

A frozen record looks safe, so this gap is easy to miss in review. The failure is quiet: there is no error, only a value that differs from what was read earlier. A spec that only checks `be_frozen` on the record does not catch it. The test must change the caller's input after construction and then check that the value did not change.

## Evidence

PR #80 adds `app/services/invoices/reservation_request.rb` and `app/services/invoices/reservation_outcome.rb`. Both constructors copy and freeze their nested values. `spec/services/invoices/reservation_request_spec.rb` builds a request from `[3, 1, 3]`, then appends to the caller's array and deletes from it. The spec checks that the request still holds `[1, 3]`, that this array is frozen, and that the caller's array is not frozen. `spec/services/invoices/reservation_outcome_spec.rb` changes a conflict's reason string, appends a conflict and changes the counts hash after construction. It checks that the outcome keeps the original values and that the caller's counts hash is not frozen. A review of the plan for this pull request raised the gap first: the value types it described kept counts exactly as given. The statement that `Data.define` freezes only the record is a fact about Ruby, not something this diff shows directly.
