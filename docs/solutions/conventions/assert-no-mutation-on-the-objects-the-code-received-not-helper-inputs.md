---
module: timekeeping_handoff
date: 2026-10-26
problem_type: convention
component: timekeeping_handoff
severity: medium
evidence_grounding: anchored
grounding_evidence: "spec/lib/timekeeping/handoff/reconciliation_spec.rb in PR #182: recon_checks_run gains source: and checkpoint: keywords, with a comment saying a prebuilt checkpoint lets a test keep the exact objects run receives. The no-write and unrepaired examples build Checkpoint.build and recon_checks_projection themselves and assert on checkpoint.rows and projection after the run."
audience: both
related_components:
  - testing_framework
tags:
  - rspec
  - no-mutation
  - test-helpers
  - reconciliation
applies_when:
  - A spec asserts that code writes nothing, mutates no input, or repairs no difference
  - A shared spec helper builds, copies or canonicalises inputs before it calls the code under test
---

# Assert no-mutation on the objects the code received, not on the hash you handed a helper

## Context

The reconciliation specs check that `Reconciliation.run` and `Reconciliation.report` never change or repair their inputs. All examples call `run` through one helper, `recon_checks_run`. Before `Checkpoint.build` and the projection mapper see the tables, that helper passes them through `recon_checks_canonical`, which fills missing columns with `reverse_merge`. That call returns a new hash.

One merged example built a `changed` tables hash, passed it to the helper, and then asserted that `changed["entries"]` still held the original notes. `run` never held `changed`. It held a canonicalised copy. So the assertion could never fail, even if `run` repaired the row in place.

## Solution

In any example that proves "nothing changed", build the objects yourself, pass those exact objects to the code, and assert on them afterwards:

```ruby
checkpoint = Timekeeping::Handoff::Checkpoint.build(tables: changed)
projection = recon_checks_projection(changed["entries"])
result = recon_checks_run(checkpoint:, projection:, listed_corrections: { 101 => [correction] })
# ... report ...
expect(checkpoint.rows["entries"].pluck("note")).to eq(%w[after after])
expect(projection.pluck("note")).to eq(%w[after after])
```

For this to work, the helper must accept prebuilt objects and use them as given. `recon_checks_run` now takes `source:` and `checkpoint:` and builds them only when they are nil (`source ||= Checkpoint.build(...)`). When you want a full no-mutation check, put every input in a `Marshal` deep copy before the run: rows, projection, intents and money snapshots. Then compare the whole set afterwards.

## Why it matters

A no-mutation test that reads a copy is worse than no test. It passes and gives false confidence. Helpers that tidy inputs (fill defaults, convert enums, deep-dup) are common and useful, so this trap comes back whenever someone moves an example onto a shared builder. Before you trust the assertion, ask: "Is this the same object identity that the code under test received?"

## Evidence

PR #182, `spec/lib/timekeeping/handoff/reconciliation_spec.rb`:

- `recon_checks_run` gains `source: nil, checkpoint: nil` keywords. The comment above them says a prebuilt checkpoint lets a test "keep hold of the exact objects run receives".
- The example "reports listed and unlisted differences without writing outside the event store and returns the result unrepaired" builds `checkpoint` and `projection` itself. It passes both to `recon_checks_run` and asserts `checkpoint.rows["entries"].pluck("note")` and `projection.pluck("note")` after `report`.
- The example "writes no row and leaves every input unchanged while it finds a difference" puts `source.rows`, `checkpoint.rows`, projection, both intent lists and both money snapshots (with a discount change from 5 to 15) into a `Marshal` deep copy. It compares all of them after the run.
