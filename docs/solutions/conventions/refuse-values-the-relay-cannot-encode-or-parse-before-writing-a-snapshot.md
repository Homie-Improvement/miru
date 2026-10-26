---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: timekeeping
severity: high
evidence_grounding: anchored
grounding_evidence: "In PR #154, timekeeping/app/services/timekeeping/snapshot_values.rb requires duration to be finite, sets METADATA_MAX_NESTING = 96 with a comment that derives it from JSON's default limit of 100 and four envelope levels, and stops nested_within? at that limit. snapshot_values_spec.rb refuses Infinity, NaN, 97-level, 10_000-level and cyclic metadata. The \"stored data\" group of correction_snapshots_spec.rb delivers 96-level metadata through the relay."
audience: both
related_components:
  - relay
  - handoff
  - entry_api
tags:
  - outbox
  - relay
  - json
  - nesting-limit
  - validation
applies_when:
  - Writing rows to an outbox that a relay later serializes to JSON and delivers in order
  - Validating free-form metadata or numeric fields on a snapshot producer
---

# Refuse values the relay cannot encode or parse before writing a snapshot

## Context

The relay sends outbox rows in order, and it moves on only after a successful delivery. A row it cannot deliver blocks every later row. The existing learning `design-patterns/a-refused-snapshot-stalls-the-relay-so-align-producer-and-skip-ignored-checks.md` covers values the consumer refuses, such as an unknown `source`.

A second group of values passes every type and enum check, commits, and then fails inside the relay itself:

- A `Float::INFINITY` or `NaN` duration is a non-negative `Numeric`, so a plain type check accepts it. JSON has no form for these values, so generating the batch raises.
- Metadata nested too deep is a valid `Hash`. The relay reads stored metadata back with JSON's default nesting limit of 100, so it raises before the row can be offered.

## Solution

Check JSON deliverability in the producer's value rules, before the transaction opens:

```ruby
"duration" => ->(value) { value.is_a?(Numeric) && value.finite? && !value.negative? },
```

Work out the metadata depth bound from the whole delivery path, not from the field alone. A snapshot carries metadata four levels down (batch, snapshots list, item, entry). The bound is therefore `METADATA_MAX_NESTING = 96`. Count Hashes and Arrays as JSON does. Keep the bound in one constant and derive other limits from it, as `EntryCommand::BODY_MAX_NESTING = SnapshotValues::METADATA_MAX_NESTING + 1` does.

Walk the metadata with a level budget that stops at the limit. Do not compute the full depth first and compare afterwards:

```ruby
levels.positive? && children.all? { |child| nested_within?(child, levels - 1) }
```

A walk that measures the full depth first raises `SystemStackError` on very deep metadata and never ends on cyclic metadata. A walk that stops at the budget refuses both, with no separate cycle check.

Test both edges through the real relay read. The deepest accepted value (96 levels) must be delivered to a receiver that parses with JSON's default limit. One level deeper must be refused with nothing written.

## Why it matters

These values fail after commit, in a different process, so the producer's own tests stay green. The visible symptom is a relay that stops for every tenant. An enum allow-list does not catch them. The producer has to ask: can this value be encoded as JSON, and can the full batch around it be parsed back?

## Evidence

- PR #154, `timekeeping/app/services/timekeeping/snapshot_values.rb`: the `duration` rule adds `value.finite?`, with the comment that JSON has no Infinity or NaN. `METADATA_MAX_NESTING = 96` has a comment that derives it from the relay's default limit of 100 and the four envelope levels. `nested_within?` stops at the level budget.
- PR #154, `timekeeping/spec/services/timekeeping/snapshot_values_spec.rb`: refuses `Float::INFINITY`, `Float::NAN`, `BigDecimal("Infinity")` and `BigDecimal("NaN")` durations. It accepts 96 levels of metadata and refuses 97. It refuses 10_000-level and cyclic metadata without exhausting the stack.
- PR #154, the "stored data" group of `timekeeping/spec/services/timekeeping/handoff/correction_snapshots_spec.rb`: writes 96-level `source_metadata` and delivers it through `TimekeepingRelay::Relay` to an endpoint that parses with `JSON.parse` defaults. It refuses 97 levels with the tables unchanged.
- PR #154, `timekeeping/app/services/timekeeping/entry_command.rb`: `BODY_MAX_NESTING = SnapshotValues::METADATA_MAX_NESTING + 1`.
