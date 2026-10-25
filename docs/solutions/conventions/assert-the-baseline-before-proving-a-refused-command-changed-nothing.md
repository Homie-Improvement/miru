---
module: timekeeping contract specs
date: 2026-10-25
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: In spec/contracts/timekeeping/reservations_examples.rb at 01f98f6, the authorization example seeds a committed-reserved entry and an agent-77 entry, asserts fields_before equals the seeded values, then compares entry_fields after every refused call; mutation_spec.rb adds one mutant row per command.
audience: both
related_components:
  - spec/support/timekeeping/fake_timekeeping.rb
  - spec/support/timekeeping/fake_arrange.rb
tags:
  - contract-tests
  - authorization
  - mutation-testing
  - unchanged-state
applies_when:
  - A spec claims a refused or failed command left stored data unchanged
  - A contract group compares state before and after a call
---

# Assert the baseline before proving a refused command changed nothing

## Context

The reservations contract sends five routes with four bad credentials and expects a refusal each time. Before this change, it checked only the response and the reservation state. Its fixtures held no entry that `mark_billed` or `detach_entries` would touch. So a provider could run the command, then return the correct refusal, and the example still passed. The check compared "nothing" with "nothing".

A "nothing changed" check has two quiet ways to pass falsely:

- The fixtures hold nothing the command would write, so a write leaves no trace.
- The read fails the same way before and after (for example an empty result or a 404), so both sides are equal even when the data moved.

## Solution

Build an unchanged-state check in four steps:

1. Seed data each refused command would change. Here that is an entry held by a committed reservation for `invoice_a` (what `mark_billed` bills) and an entry carrying `agent_id: 77` (what `detach_entries` clears).
2. Take the baseline once, after seeding, and assert it holds the seeded values:

```ruby
fields_before = entry_fields(billable, agent_entry)
expect(fields_before).to eq(
  billable => { "bill_status" => "unbilled", "agent_id" => nil },
  agent_entry => { "bill_status" => "unbilled", "agent_id" => 77 }
)
```

3. Compare against that one baseline after every refused call, labelled with the route. Never re-capture it inside the loop, because a re-captured baseline absorbs an earlier leak.
4. Add one mutant per command that writes before refusing. Here the fake gains a `refused_command_writes: ->(route:) { false }` policy, and `mutation_spec.rb` adds one row for `mark_billed` and one for `detach_entries`. A single mutant that writes both fields would still fail the group if one field check were missing, so it would not prove each check works.

Read the fields through the arrange adapter (`timekeeping_arrange.stored_entry`), not through another group's route. Contract groups can run on their own, so a reservation-only provider need not serve the entry API.

## Why it matters

An equality check between two reads proves nothing unless the reads are known to see real data. Asserting the seeded values turns a broken reader or failed seeding into a failing example instead of a false "unchanged". Seeding writable data gives a write-before-refusing provider something to change. The per-command mutants show that each field check can fail on its own.

The same gap stays open in the stale-generation example of the same file. Its `mark_billed` and `detach_entries` calls still have nothing to write. Apply these steps there too.

## Evidence

- PR #42, head commit 01f98f6636011588d1e0fb2a912927ca48a49782.
- `spec/contracts/timekeeping/reservations_examples.rb`: the authorization example seeds `billable` and `agent_entry`, asserts `fields_before` against the seeded values, and runs `expect([route, entry_fields(billable, agent_entry)]).to eq([route, fields_before])` after every refused call.
- `spec/support/timekeeping/fake_timekeeping.rb`: adds the `refused_command_writes` policy with a default of `false`, and `reservation_request` runs the route's command before returning the refusal when the policy returns true.
- `spec/contracts/timekeeping/mutation_spec.rb`: adds the rows "bills entries before refusing a reservation command" and "detaches entries before refusing a reservation command".
- `spec/support/timekeeping/fake_arrange.rb`: delegates `stored_entry`, with a comment that the reservations group reads fields here because a provider may run it without the entry API.
