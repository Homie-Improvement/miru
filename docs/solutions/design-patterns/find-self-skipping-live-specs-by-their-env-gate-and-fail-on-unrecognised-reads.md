---
module: ci
date: 2026-11-21
problem_type: design_pattern
component: testing_framework
severity: medium
audience: both
related_components:
  - development_workflow
tags:
  - live-specs
  - timekeeping-live
  - spec-discovery
  - fail-closed
applies_when:
  - A CI job must run every spec that skips itself unless an environment flag is set
  - The job finds those specs automatically rather than from a fixed list
---

# Find self-skipping live specs by their env gate, and fail on reads you do not recognise

## Context

The live Timekeeping specs under `spec/integration/timekeeping` skip themselves unless `TIMEKEEPING_LIVE` is `"1"`. A normal suite run never runs them, so the live CI job is the only place they run. If the job's discovery misses one, that spec goes unrun everywhere and the check stays green.

The first design matched the file name `*_live_spec.rb`. That missed `live_instance_generation_spec.rb`, which boots a real server and gates on the flag. The next version left out any spec that mentioned `TIMEKEEPING_REGRESSION`. A runnable spec with only a comment naming that flag then dropped out too.

## Solution

In `script/ci/timekeeping_live_specs.rb`, a spec counts as live by what its source does:

- It is live when it matches `LIVE_GATE`, which accepts `ENV["TIMEKEEPING_LIVE"] == "1"` in either quote style and with any spacing.
- It is left out only when it *reads* `ENV["TIMEKEEPING_REGRESSION"]` (`REGRESSION_GATE`). This job does not set that flag, so those specs would only skip here. A comment that names the flag is not a read.
- If a spec contains `TIMEKEEPING_LIVE` but matches neither rule (for example an `ENV.fetch` form), `live_specs` raises `ConfigError` and the job exits 1. Silently leaving it out would let the check pass with that spec unrun.

The meta spec asks the script for its inventory (`TimekeepingLiveSpecs.live_specs`) instead of copying the rule. This keeps the rule in one place.

## Why it matters

A name rule or a substring rule fails quietly: the spec drops out and nothing turns red. Reading the real gate picks up each new live spec without editing the script. Raising on a gate the script cannot read turns the next unknown case into a red build, not a hidden gap. The same reasoning applies to any self-skipping spec family keyed on an environment flag. Only this flag pair was checked here.

## Evidence

- PR #529 defines `LIVE_GATE`, `REGRESSION_GATE`, `live_spec?` and `live_specs` in `script/ci/timekeeping_live_specs.rb`. `live_specs` raises `ConfigError` for a file that includes `LIVE_FLAG` without the gate and without a regression read.
- `spec/scripts/ci/timekeeping_live_specs_spec.rb` in this pull request makes these checks. The real directory gives exactly `alerts_live_spec.rb`, `handoff_live_spec.rb` and `live_instance_generation_spec.rb`. A single-quoted gate is listed. An `ENV.fetch` gate makes `live_specs` raise and `run` return 1 without the no-spec line. A comment naming `TIMEKEEPING_REGRESSION` does not make `live_spec?` false.
- `spec/meta/ci_spec_coverage_spec.rb` in this pull request calls `TimekeepingLiveSpecs.live_specs(root: Rails.root.to_s)` to check that the handoff and alerts specs are in the inventory.
