---
module: timekeeping_ownership
date: 2026-11-19
problem_type: design_pattern
component: timekeeping_handoff
severity: medium
audience: both
related_components:
  - seeds
  - analytics_demo_seeder
  - users_controller
tags:
  - handoff-begun
  - admission-fence
  - ownership-row
  - single-predicate
applies_when:
  - A handoff or migration step writes only a mark column, such as a fenced-at timestamp, and leaves the other state columns at their initial values
  - Several callers refuse through one shared 'has it begun' predicate
---

# Count a handoff's first mark column as begun in the shared predicate

## Context

`TimekeepingOwnership#handoff_begun?` decides when seed runs, `Analytics::DemoSeeder` and the super-admin user hard delete must refuse. It treated a handoff as begun when `generation`, `handoff_step`, `owner` or `monolith_store` left its initial value.

The handoff's first write is `MonolithAdmission#fence_admission`. It sets only `admission_fenced_at`. So while the fence was set, and for as long as a `close_admission` lock timeout left the row fenced, the row still looked initial. The seeds and the hard delete ran while every other monolith writer was already refused.

The symptom was two answers for one state. A fenced delete of a user with agents failed with 503 `ownership_moving` deep in the gateway cascade. A fenced delete of a user without agents succeeded.

## Solution

Add the mark to the one predicate, not to each caller:

```ruby
def handoff_begun?
  generation > INITIAL_GENERATION ||
    !handoff_step.nil? ||
    owner != INITIAL_OWNER ||
    monolith_store != INITIAL_MONOLITH_STORE ||
    !admission_fenced_at.nil?
end
```

All callers reach it through the class helpers `refuse_if_handoff_begun!` (the three seed builders) and `unless_handoff_begun` (the users controller). One clause changes all of them, and no caller copies the rule.

The mark is transient: an abort's `admit` clears it. That makes "begun" reversible, which is safe here only because nothing has moved yet. `close_admission` is the first statement that raises `generation`, and a raised generation stays begun for good. If you add a mark column to such a predicate, check the same thing: clearing it must return the row to a state where nothing has changed.

When a new step writes a new column, ask whether that column alone can be the only departure from the initial row. If yes, it belongs in the predicate.

## Why it matters

A predicate named "begun" that misses the first step's column lets guarded writers slip through exactly at the moment the system is closing. The hard delete cannot be undone, so it is the worst writer to let through. Exempting callers instead would keep the 503-or-success split and leave a second rule for every new caller to remember.

The spec that tests the predicate one column at a time must list the mark too, and reset it between columns. Otherwise a fenced row stays invisible to tests as well as to code.

## Evidence

- PR #383 adds `!admission_fenced_at.nil?` to `handoff_begun?` in `app/models/timekeeping_ownership.rb`, with a comment that the fence is the handoff's first write and that `admit` clears it.
- PR #383 adds `admission_fenced_at: Time.current` to the column table in `spec/models/timekeeping_ownership_spec.rb` and resets `admission_fenced_at: nil` before each column.
- `spec/requests/api/v1/users/destroy_spec.rb` in PR #383 shows a fenced delete of a user with agents now gets 422 with the fixed `user.super_admin_delete.handoff_begun` message, and the agent and entry `agent_id` stay unchanged. Its comment states that without the fence in the begun rule this delete fails with 503 `ownership_moving` while a user with no agents is deleted.
- `spec/db/seeds_handoff_refusal_spec.rb` and `spec/models/timekeeping_ownership_spec.rb` in PR #383 show refusal on a fenced-only row and reopening after `Timekeeping::Handoff::MonolithAdmission.new.admit(generation: 1)`.
- `docs/architecture/timekeeping-soa.md` in PR #383 states the fence mark counts as begun and that builders may run again once an abort clears it.
