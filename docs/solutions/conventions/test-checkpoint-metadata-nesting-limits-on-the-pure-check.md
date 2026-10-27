---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: handoff
severity: low
evidence_grounding: speculative
audience: author
related_components:
  - checkpoint_entry_values
  - snapshot_values
tags:
  - checkpoint
  - metadata-nesting
  - testing
applies_when:
  - Writing tests for metadata depth rules on entries that travel in a handoff checkpoint
---

# Test checkpoint metadata nesting limits on the pure check

## Context

Entry metadata (`source_metadata`, `proof_metadata`) may nest at most 96 levels; 97 is refused. A natural test builds a real checkpoint with that metadata and loads it through `ServiceStore#load_checkpoint`.

That test cannot work. `Checkpoint.build` computes a checksum over the encoded rows, and the encoder wraps each metadata level in several extra JSON arrays. The JSON generator's default nesting limit is reached long before 96 metadata levels, so the fixture fails while its digest is computed. The value check never runs, and the 96-level case can never load.

## Solution

Test the 96/97 edges directly on the pure check, `Timekeeping::Handoff::CheckpointEntryValues.invalid_entries`, with plain row hashes. Do not pass them through `Checkpoint.build`. Use shallow metadata the checkpoint can carry in store and request tests that must load successfully.

## Why it matters

On this path the nesting rule only guards checkpoints built in process. A store-level boundary test fails for a reason unrelated to the rule, and the obvious fix (raising the encoder limit) changes a shared format that the monolith also loads.

## Evidence

- PR #179 adds `timekeeping/spec/services/timekeeping/handoff/checkpoint_entry_values_spec.rb`. Its nesting example uses plain rows, and its comment says the checkpoint checksum cannot encode metadata this deep, so the edges are only reachable on the pure check.
- The detail about array wrapping and the generator's default nesting limit comes from the shared checkpoint encoder, which this pull request does not change. Treat it as a step to verify there, not as evidence from this change.
