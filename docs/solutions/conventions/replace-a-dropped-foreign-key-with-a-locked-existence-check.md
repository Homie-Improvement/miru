---
module: Timekeeping
date: 2026-10-25
problem_type: convention
component: data_model
severity: high
evidence_grounding: speculative
audience: both
related_components:
  - timesheet_entries
  - invoice_line_items
  - agents
tags:
  - foreign-keys
  - validations
  - rails
  - locking
  - referential-integrity
applies_when:
  - Dropping a database foreign key and moving its check into the model
  - Writing a validation that a supplied id names an existing row
---

# Replace a dropped foreign key with a locked existence check

## Context

A foreign key refuses any id that names no row, at the moment of the insert. When a key is dropped, a model validation has to take over that refusal. The obvious Rails version, `validates :agent, presence: true, if: :agent_id?`, refuses less than the key did, in three ways:

- `agent_id?` is false for an id of `0`, so the check is skipped and `0` is saved.
- `presence` on an association accepts an already loaded object, even if another request deleted its row after it was loaded.
- Even a fresh query can pass and then the parent row can be deleted before the save commits.

In PR #44 the keys `invoice_line_items -> timesheet_entries` and `timesheet_entries -> agents` were dropped, and review found the first two gaps in the first draft of the checks.

## Solution

Guard on nil, not on truthiness. Query the parent table, not the association cache. Take a share lock on the parent row, and make the parent's destroy take a row lock first.

```ruby
# app/models/invoice_line_item.rb
validates :timesheet_entry, presence: { message: :required }, unless: -> { timesheet_entry_id.nil? }

# app/models/timesheet_entry.rb
validate :validate_agent_exists, if: -> { !agent_id.nil? && will_save_change_to_agent_id? }

def validate_agent_exists
  return if Agent.where(id: agent_id).lock("FOR SHARE").exists?
  errors.add(:agent, :required)
end

# app/models/agent.rb
before_destroy :lock!, prepend: true
```

`prepend: true` matters: the lock must run before `dependent: :nullify` detaches the entries. Then a concurrent entry save either commits first and gets detached, or waits and fails its check.

Add specs for an id of `0` and for a cached parent whose row was deleted. These are the cases the naive check lets through.

## Release the checks first

Ship the validations in one release and drop the key in a later one. Deploys here migrate while processes from the previous release still write: `bin/docker-entrypoint` runs `db:prepare` in the first new container of a rolling boot, and the Solid Queue workers run old code until they are replaced. If the key and its validation change together, those old processes write with neither. An app-only rollback to that release would do the same with no time limit. PR #44 first shipped them together; `db/migrate/20261020120000_drop_timesheet_entry_foreign_keys.rb` now keeps the keys, and step S1 in `docs/architecture/timekeeping-soa.md` section 10.2 records the order and how to restore the keys on a database that already lost them.

## Why it matters

Without these, a dropped key silently starts accepting dangling ids. Those rows also block the migration's rollback, because restoring the key would fail on them. The refusal still changes form, from a database error to a validation error, so callers that rescued the database error need a look too.

## Evidence

PR #44, head commit `9ee9f2d66a4aeb1560bcdf330cd68ab38e7d536b`:

- `db/migrate/20261020120000_drop_timesheet_entry_foreign_keys.rb` drops the three keys and its `down` counts dangling references and raises `DanglingReferencesError` before restoring anything.
- `app/models/invoice_line_item.rb` adds the existence check guarded by `timesheet_entry_id.nil?`.
- `app/models/timesheet_entry.rb` adds `validate_agent_exists` with `lock("FOR SHARE")`, guarded by `!agent_id.nil?`.
- `app/models/agent.rb` adds `before_destroy :lock!, prepend: true` with a comment on the race it closes.
- `spec/models/invoice_line_item_spec.rb` and `spec/models/timesheet_entry_spec.rb` add examples that an id of `0` is invalid. `spec/models/timesheet_entry_spec.rb` adds an example that a save with a cached agent whose row was destroyed returns false.
- The statement that `agent_id?` is false for `0` comes from a review finding on this pull request that the author confirmed. The diff shows the fix and its specs, not the original failing run.
