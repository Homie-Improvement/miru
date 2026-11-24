---
module: timekeeping
date: 2026-11-24
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - invoices
  - timekeeping-handoff
tags:
  - lock-removal
  - concurrency-specs
  - operation-lock
  - live-specs
applies_when:
  - Proving that a concurrency spec fails when the lock, fence or settle step it claims to test is removed
  - The lock is taken at more than one call site on the same path
  - The same method exists in both the monolith and the timekeeping/ tree
---

# Remove every acquisition, in the tree the process loads, when proving a lock by removal

## Context

A concurrency spec is only useful if it goes red when its lock is gone. To check this, you remove the lock in the working tree, run the spec, and restore the file. A removal run can stay green for two reasons that have nothing to do with the spec:

- The path takes the lock at more than one place. The invoice save path calls `Invoices::OperationLock.acquire!` in `Flush#call` (`app/services/invoices/reservation_boundary.rb`) and in `lock_current_generation!` (`app/services/invoices/operation_coordinator.rb`). If you remove only one call, the other one still makes the saves run one after the other.
- The method has more than one copy. `lock_entries` exists in the monolith and in `timekeeping/app/services/timekeeping/reservation_operations.rb`. The live "Two invoices prepare one entry at once" example runs after cutover against the Timekeeping server, which boots from the `timekeeping/` tree. Editing a monolith copy changes nothing that this example runs.

## Solution

Before a removal run, find every place where the path you are testing takes the lock. Remove all of them together. Then work out which process runs the code during the example, and edit the copy that process loads. Record which calls you removed and which copies you left alone, with the reason, so a reader can repeat the run.

If the example still passes after a complete removal, the spec really is weak. Strengthen it by asserting which lock it waits on.

## Why it matters

An incomplete removal gives a false green. The reader then either distrusts a good spec or rewrites it for no reason. The opposite error is worse: a spec that only passes because a second call site still holds the lock looks proven when it is not. Naming the exact calls removed keeps the removal record honest and repeatable.

## Evidence

- PR #608 adds a removal record to `docs/solutions/conventions/identify-the-lock-a-session-waits-on-not-only-that-it-is-blocked.md`.
- Under "Save-path invoice-identity lock", the record removes both `Invoices::OperationLock.acquire!` calls, in `app/services/invoices/reservation_boundary.rb` and `app/services/invoices/operation_coordinator.rb`. It states: "Removing only one leaves the save serialized by the other."
- Under "Timekeeping entry lock", it removes `.lock("FOR UPDATE")` from `lock_entries` in `timekeeping/app/services/timekeeping/reservation_operations.rb`. It states that the monolith copies were left alone "because the live example runs after cutover against the Timekeeping server". With that removal, the two-prepares example and 5 of the 8 examples in `timekeeping/spec/services/timekeeping/reservation_operations_race_spec.rb` failed.
