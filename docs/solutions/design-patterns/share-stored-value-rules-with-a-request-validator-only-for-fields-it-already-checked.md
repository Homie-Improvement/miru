---
module: timekeeping
date: 2026-10-26
problem_type: design_pattern
component: timekeeping
severity: high
evidence_grounding: anchored
grounding_evidence: 'In PR #154, timekeeping/app/services/timekeeping/entry_command.rb sets FIELD_SHAPES to SnapshotValues::RULES.slice over an explicit list of nine fields. Its comment says project_id is left out because parse_project_id accepts a decimal string that the snapshot rule would refuse. entry_command_spec.rb checks that project_id "11" still builds on create, update and bulk_move.'
audience: both
related_components:
  - entry_api
  - handoff
tags:
  - validation
  - shared-rules
  - request-parsing
  - snapshots
applies_when:
  - A request validator starts reusing value rules written for stored rows or outbound snapshots
  - A request field is parsed or cast before it is stored, while the validator reads the raw body
---

# Share stored-value rules with a request validator only for the fields it already checked

## Context

`Timekeeping::SnapshotValues::RULES` holds one rule for each field of an entry snapshot. A snapshot is the stored form of an entry that the relay sends to the monolith. Each rule describes the value as it is stored. For example, `project_id` must be a positive `Integer`.

`EntryCommand` checks request bodies for the entry API. `EntryCommand.check_fields!` reads the raw body. Some fields reach storage through a parser first. `parse_project_id` accepts the decimal string `"11"` and returns `11`, but it leaves the body unchanged.

The obvious way to share the rules is `RULES.slice(*WRITABLE_FIELDS)`. That list includes `project_id`. With that slice, the raw `"11"` reaches the snapshot rule, and every create, update or bulk_move that sends `"11"` is refused, although the API accepts it today.

## Solution

Slice the shared table by the exact list of fields the request validator already checked, written out by name:

```ruby
FIELD_SHAPES = SnapshotValues::RULES.slice(
  *%w[work_date duration note source source_metadata bill_status agent_id proof_url proof_metadata]
).freeze
```

A field that has its own parser, such as `project_id` with `parse_project_id`, stays with that parser. Add a short comment that says why the field is left out. Pin the choice with specs:

- a spec that checks the `FIELD_SHAPES` keys equal that list and that each rule is the shared rule;
- a regression spec that sends the parsed form (`project_id: "11"`) on every route that reads it.

## Why it matters

A stored-value rule describes the value after parsing. A request validator sees the value before parsing. When the two differ for a field, the shared rule is stricter than the API's contract. Clients that worked yesterday then get 400 responses, and nothing in the diff looks like an API change.

The cost of the explicit list is one place to update when the API starts checking a new field. That is cheaper than a silent narrowing of accepted requests. If a parsed field must be checked against the shared rule, check the parsed value, not the raw body.

## Evidence

- PR #154, `timekeeping/app/services/timekeeping/entry_command.rb`: `FIELD_SHAPES` becomes `SnapshotValues::RULES.slice` over the nine named fields. The comment says `project_id` is not there because `parse_project_id` accepts a decimal string the snapshot rule would refuse.
- PR #154, `timekeeping/app/services/timekeeping/snapshot_values.rb`: `"project_id" => id`, where `id` requires a positive `Integer`.
- PR #154, `timekeeping/spec/services/timekeeping/entry_command_spec.rb`: tests check the nine `FIELD_SHAPES` keys and that each rule equals `SnapshotValues::RULES[field]`. They also check that `project_id` `"11"` still builds a command on create, update and bulk_move.
