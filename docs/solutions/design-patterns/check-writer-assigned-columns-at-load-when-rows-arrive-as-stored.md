---
module: timekeeping
date: 2026-10-26
problem_type: design_pattern
component: handoff
severity: high
evidence_grounding: anchored
grounding_evidence: timekeeping/app/services/timekeeping/handoff/checkpoint_entry_values.rb builds RULES as SnapshotValues::RULES.except("locked").merge("version" => SnapshotValues::RULES.fetch("id")), and service_store_spec.rb refuses version 0 and -1 on an empty destination
audience: both
related_components:
  - snapshot_values
  - service_store
tags:
  - checkpoint
  - version
  - outbox
  - projection
applies_when:
  - A load or import inserts rows with columns that live writers normally assign themselves
  - A shared rule list leaves a field out because writers set it
---

# Check writer-assigned columns at load when rows arrive as stored

## Context

`Timekeeping::SnapshotValues` lists the values the monolith's projection accepts for each entry field. It leaves out `version`, because every live writer assigns the version itself, so a bad one cannot come from a request.

A checkpoint load is different. It inserts entry rows exactly as the monolith stored them, `version` included. The load already compares each incoming version against the stored row with the same id and refuses an older one. That comparison only runs when a stored row exists. On an empty destination it compares nothing, so a version of `0` or `-1` loads. The next write then keeps it non-positive, the outbox republishes it, the projection refuses the batch, and delivery of every later snapshot stops.

## Solution

When a path receives rows as stored, check the writer-assigned columns too, with the rule the projection applies. In this change the load reuses the existing positive-Integer rule for `id` rather than writing a new one:

```ruby
RULES = SnapshotValues::RULES.except("locked").merge("version" => SnapshotValues::RULES.fetch("id")).freeze
```

Keep the separate older-version comparison. It answers a different question (is this checkpoint stale?) and does not replace the value check.

## Why it matters

A rule list built for live writers describes what writers may send, not what a stored row may hold. Reusing it unchanged for an import silently drops the columns writers control. A comparison against existing rows looks like validation but proves nothing when there are no rows yet, which is exactly the first load of a cutover.

## Evidence

- PR #179 adds `timekeeping/app/services/timekeeping/handoff/checkpoint_entry_values.rb`. Its comment says a checkpoint carries version as stored, so it gets the projection's positive-Integer rule, the same as `id`.
- `timekeeping/spec/services/timekeeping/handoff/service_store_spec.rb` adds an example that refuses version `0` and `-1` on an empty destination, with every stored table unchanged. Its comment notes that no stored version is compared there.
- `timekeeping/spec/services/timekeeping/snapshot_values_spec.rb` keeps the existing assertion that `RULES.keys` equals the outbox entry fields minus `"version"`, showing the shared list omits it.
