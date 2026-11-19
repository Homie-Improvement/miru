---
module: timekeeping
date: 2026-11-19
problem_type: design_pattern
component: service_layer
severity: high
audience: both
related_components:
  - TimekeepingOwnership
  - Timekeeping::LocalOwner::WriteSteps
  - Timekeeping::LocalOwner::ReservationOperations
  - Invoices::PreparedReservations
tags:
  - handoff
  - settle-step
  - generation
  - admission
  - snapshots
applies_when:
  - A handoff is in progress and an outgoing owner must still finish some requests while refusing everything else
  - Several writers share one admission check and only one kind of request needs an exception
  - A writer passes a generation into the snapshots it publishes
---

# Admit settle-step finishes through a separate rule that returns the outgoing generation

## Context

A handoff moves ownership of time entries from the monolith to the Timekeeping service. It raises the `generation` column on the single `timekeeping_ownership` row and records a `handoff_step`. While that step is recorded, admission is closed: entry writes, service commands and reservation writes are all refused as `stale_generation`.

During the "settle step" the outgoing owner must still finish one kind of work. It applies a commit or abort of an invoice operation it registered at the old (outgoing) generation. Everything else stays refused. This is the rule in docs/architecture/timekeeping-soa.md section 10.5.

There are two easy ways to get this wrong:

1. **Relax the shared check.** One option is to widen `WriteSteps.admitted_generation`, for example by letting it return the settling generation. Entry writes and `ServiceCommands` read the same check, so this would quietly reopen them during the handoff.
2. **Write at the wrong generation.** The reservation route used to pass the admitted generation from the row into the commit, and the commit stamps it on the entry snapshots it publishes. During a handoff the row holds the raised generation. Reusing it would label pre-freeze work with the new owner's generation, so the money snapshot taken at the freeze would no longer match.

## Solution

Keep `admitted_generation` unchanged. Add a separate pure rule beside it that answers only the settle-step question. It returns the generation to write at, or `nil` for a refusal:

```ruby
def settling_generation(ownership, route:, generation:, operation_generation:)
  return if ownership.nil? || ownership.handoff_step.nil? || EntryOwner.for(ownership) != :prepared
  return unless SETTLING_ROUTES.include?(route)

  settling = ownership.settling_generation
  return unless generation_matches?(generation, settling) && operation_generation == settling

  settling
end
```

Each writer picks one of two branches, depending on whether a handoff step is recorded:

```ruby
def generation_to_write(ownership)
  if ownership&.handoff_step
    WriteSteps.settling_generation(ownership, route:, generation:, operation_generation: find_operation&.generation)
  else
    admitted = WriteSteps.generation_admitted_by(ownership)
    admitted if WriteSteps.generation_matches?(generation, admitted)
  end
end
```

The value this returns is the generation the commit writes at: `send(ROUTES.fetch(route), write_generation)`. During a handoff that is the outgoing generation the operation was stored at, never the raised one. `Invoices::PreparedReservations#finish` calls the same rule from its `finish_admitted?` method, so both writers decide the exception in one place.

## Why it matters

- A shared admission check is read by more callers than the one you are changing. An exception for one route belongs in its own rule, with the route spelled out in it (`SETTLING_ROUTES = %i[commit abort]`).
- Returning the generation, not a yes/no answer, makes the writer use the value the rule checked. With a yes/no answer, the old code would keep passing the row's generation, which is the raised one during a handoff.
- Both tests are easy to forget. A commit that only promotes a reservation publishes no snapshot, so it cannot catch a wrong generation. Without a refusal test, nothing shows that entry writes stay closed.

When you add a similar exception, test both sides:
- A settling commit that releases an entry publishes exactly one snapshot at the outgoing generation.
- Entry writes, service commands and Gateway writes are still refused while the step is open.

## Evidence

- PR #385 adds `settling_generation` and `generation_admitted_by` to `app/services/timekeeping/local_owner/write_steps.rb`. `admitted_generation` itself only delegates to `generation_admitted_by`, and its admission logic is unchanged.
- PR #385 adds `generation_to_write` in `app/services/timekeeping/local_owner/reservation_operations.rb`. The method it calls receives `write_generation`, not the stored generation.
- In `app/services/invoices/prepared_reservations.rb`, `finish_admitted?` calls `Timekeeping::LocalOwner::WriteSteps.settling_generation`.
- `spec/services/timekeeping/local_owner_settling_spec.rb` and `spec/services/invoices/prepared_reservations_settling_spec.rb` each test a settling commit that releases an already committed entry. Each asserts that the new snapshot rows equal `before + [outgoing]`, the outgoing generation, not the raised one.
- `spec/services/timekeeping/local_owner_fence_spec.rb` checks that an entry create during the settle step is refused as `stale_generation` at both the outgoing and the raised generation.
- `spec/services/timekeeping/local_owner_settling_spec.rb` checks that a `mark_billed` service command and a `BillingFence` write are refused while the settle step is open.
- `spec/services/timekeeping/gateway_spec.rb` checks that a Gateway create raises `OwnershipMoving` and writes nothing.
- The rule rests on docs/architecture/timekeeping-soa.md section 10.5, which the change cites in its comments.
