---
module: spec/support/timekeeping
date: 2026-11-23
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/meta
tags:
  - rspec-metadata
  - prism
  - static-spec-checks
  - integrated-runtime
applies_when:
  - A meta spec checks that examples in another spec file carry an RSpec tag
  - A tag's hooks turn on a guard, such as the teardown queue ledger, and an untagged example would run unwatched
---

# Read RSpec metadata only after the description argument in static tag checks

## Context

The live timekeeping specs depend on the `:integrated_runtime` tag. Its hooks start the integrated runtime and turn on the teardown queue ledger, which fails the suite when a job from a non-dedicated queue ran. An example without the tag runs with no ledger watching it.

The meta spec used to check `expect(source).to include(":integrated_runtime")`. That passes when the text appears only in a comment, so removing the tag from the group would not fail it.

Two other forms also look tagged but are not. RSpec reads the first argument of `describe`, `context` or `it` as the description. So `it :integrated_runtime do` names the example, and `context(integrated_runtime: true)` or `context({ integrated_runtime: true })` makes the hash the description. In all three cases the example gets no metadata and the hooks do not run.

## Solution

Parse the spec source and walk group and example calls. Read the tag only from arguments after the first one: a bare symbol, or a key in a hash. `TimekeepingIntegrationTags.runtime_tag_setting` does this with `(node.arguments&.arguments || []).drop(1)`.

Pass the tag down from groups to the examples inside them. Do not treat `it` or `context` calls inside an example body or a hook as declarations.

Refuse source that does not parse. Raise instead of reading a recovered tree, because recovery can drop the very example that lacks the tag.

Test the check against each false form: a comment, a string, a symbol description, a braced hash description and a keyword hash description. Each must be reported.

## Why it matters

A guard on a tag exists to catch the example that silently skips the tag's hooks. A check that accepts a comment or a description as the tag passes in exactly that case. The live specs are also skipped in the default suite, so nothing else shows the gap.

The existing `committed_data` check (`tag_setting`) still scans every argument, so `it :committed_data do` counts as tagged there. This change leaves it as is; do not copy that reader for a new tag.

## Evidence

- PR #585 adds `TimekeepingIntegrationTags.missing_integrated_runtime` and `runtime_tag_setting` in `spec/support/timekeeping/integration_tags.rb`. The reader drops the first argument and raises `ArgumentError` when `Prism.parse` does not succeed.
- In `spec/meta/timekeeping_integration_tags_spec.rb`, the substring check is replaced by the structural check. New examples report a comment, a string and a symbol description ("more tests 12"), and a lone braced or keyword hash ("a lone hash argument").
- During review, the author built `context({ integrated_runtime: true })` with real RSpec. Before the fix it printed `{runtime_metadata: nil, description: "{integrated_runtime: true}", reported_lines: []}`: RSpec set no metadata, and the check reported nothing. After the fix it printed `{runtime_metadata: nil, reported_lines: [1]}`.
