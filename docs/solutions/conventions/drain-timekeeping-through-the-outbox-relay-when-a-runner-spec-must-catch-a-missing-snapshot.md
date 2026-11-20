---
module: timekeeping-handoff
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - Timekeeping::Handoff::Runner
  - Timekeeping::ProjectionConsumer
  - TimekeepingHandoffFakes
tags:
  - handoff
  - outbox
  - fake-relay
  - projection
  - runner-specs
applies_when:
  - Writing a Timekeeping::Handoff::Runner spec that should fail when a raised or corrected entry's snapshot is never written to Timekeeping's outbox
  - Adding or changing a test drain for Timekeeping as the outgoing owner
---

# Drain Timekeeping through the outbox relay when a runner spec must catch a missing snapshot

## Context

On a live rollback, the monolith's `timesheet_entries` projection changes only when Timekeeping's outbox relay delivers a snapshot to `Timekeeping::ProjectionConsumer`. If the runner forgets to write a snapshot for a raised or corrected entry, the projection keeps the old version. Reconcile then refuses the rollback.

The default fake drain, `TimekeepingHandoffFakeRelay`, does not work that way. It copies every stored entry straight into the projection, with `locked` set from the entry's reservations through `Timekeeping::Handoff::ReservationLocks.build` rather than the stored column. A runner spec on the default `TimekeepingHandoffFakes.owners(timekeeping:)` therefore passes even when a snapshot is missing. The bug shows up only on a live run.

## Solution

When a spec must prove that every snapshot reached the outbox, build owners with the outbox relay:

```ruby
owners = TimekeepingHandoffFakes.owners(timekeeping:, relay: :timekeeping_outbox)
```

This keeps the monolith's copy relay and gives Timekeeping a `TimekeepingHandoffOutboxRelay`. That relay:

- delivers only rows in `InMemoryTimekeepingStore#outbox`, through the real `Timekeeping::ProjectionConsumer`, using the gem's own `TimekeepingRelay::Relay`;
- never reads stored entries and never writes the projection itself, so there is no second write path that could hide the gap;
- holds back rows of a generation the store never admitted, and rows above `through`;
- raises `TimekeepingHandoffOutboxRelay::Undelivered` with the consumer's status and body when a batch is refused (409, 422 or any other answer), and `drained?` stays false.

The relay reads admitted generations from the store's own `admit` calls. So the store must also be Timekeeping's admission; `owners` raises `ArgumentError` when you pass a different `timekeeping_admission` with this relay.

To prove the spec discriminates, drop one snapshot in a spec-local store subclass that overrides `write_correction_snapshots` and calls `super` without it. Do not add a break switch to the shared fake.

## Why it matters

A fake that is more forgiving than the real path turns a live failure into a green spec. The loud `Undelivered` error matters too. Without it, a shape or generation mistake in the fake would look the same as a projection left behind, or would not fail at all. Then the spec could not tell a fake bug from a runner bug.

The copy relay is still the default for both owners. Only specs that opt in get this protection, so a new runner spec about snapshot delivery must ask for it.

## Evidence

- PR #481 adds `TimekeepingHandoffOutboxRelay`, the store's `outbox`, and the `RELAY_DRAINS` table with the `:timekeeping_outbox` entry in `spec/support/timekeeping/handoff_fakes.rb`. The `RELAY_DRAINS` `true` entry keeps `TimekeepingHandoffFakeRelay` for both owners as the default.
- `spec/lib/timekeeping/handoff/runner_outbox_relay_spec.rb` ("a raised entry's snapshot left out of Timekeeping's outbox ...") omits one raised entry through a store subclass. The rollback raises `Timekeeping::Handoff::Runner::Refused`, and `reconciliation.json` lists that entry with check `projection`, field `version`, reason `changed`. Its sibling example, with nothing omitted, finishes the rollback with `abort` false.
- `spec/contracts/timekeeping/handoff_fakes_spec.rb` covers the hold-back of an unadmitted generation, the `through` bound, the 422 and 409 `Undelivered` refusals, and the `ArgumentError` when `relay: :timekeeping_outbox` gets a separate admission.
- `spec/lib/timekeeping/handoff/runner_legacy_handoff_spec.rb` switches two existing examples to `relay: :timekeeping_outbox` with unchanged assertions.
