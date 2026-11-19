---
module: spec/support
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/support/two_tenant_seed.rb
  - spec/support/database_cleaner.rb
tags:
  - rspec
  - before-all
  - committed-data
  - two-tenant-seed
  - metadata-override
applies_when:
  - A before(:all) hook skips setup because a per-example hook already does the same setup
  - The per-example hook decides from example metadata that a nested group or example can override
---

# Decide a before(:all) skip per example, with the per-example hook's rule

## Context

The `two tenant seed` shared context in `spec/support/two_tenant_seed.rb` truncates the database and loads the seed once, in `before(:all)`. A group tagged `committed_data: true` gets a second load before every example. The committed_data hook in `spec/support/database_cleaner.rb` deletes every table and reloads the seed for each example where `TestDatabaseCleanup.seeded_committed?(example.metadata)` is true. So for those groups the group-level load is wasted time, and PR #389 skips it.

The obvious guard reads the group's own tags: skip when the group says `committed_data: true`. That guard is wrong. RSpec lets a nested group or a single example set `committed_data: false`. The per-example reload then does not run for that example. With the group load also skipped, the example runs on an empty database and seed lookups such as the two seeded companies are not found.

## Solution

Ask the same question the per-example hook asks, for every example the group will run, and skip only when all of them say yes:

```ruby
before(:all) do
  examples = self.class.descendant_filtered_examples
  next if examples.all? { |example| TestDatabaseCleanup.seeded_committed?(example.metadata) }

  DatabaseCleaner.clean_with :truncation, except: %w(ar_internal_metadata)
  Timekeeping::SeedDispositionRecorder.load_fresh_seed!(as_of: TestDatabaseCleanup.seed_as_of)
end
```

`descendant_filtered_examples` covers the examples in nested groups too, after filtering, so the decision matches what actually runs. The rule lives in one place, `TestDatabaseCleanup.seeded_committed?`; the group hook calls it instead of copying its logic.

Test both sides. One spec runs a group tagged `committed_data: true, two_tenant_seed: true` and checks the seed loads exactly once, from the per-example reset. A second spec puts one `committed_data: false` example in that group and checks it still sees the seeded companies. To tag the example alone, `run_inner_example_through_suite_hooks` in `spec/support/inner_example_through_suite_hooks.rb` now takes an optional `example_metadata` argument.

## Why it matters

The failure is silent until someone writes the override. No spec combined these tags when the skip was added, so a group-metadata guard passes the whole suite. The first author who turns committed_data off inside such a group then gets a not-found error far from its cause. The same trap applies to any group-level hook that leaves work to a per-example hook keyed on overridable metadata.

## Evidence

- PR #389 changes `spec/support/two_tenant_seed.rb` to guard the `before(:all)` load with `descendant_filtered_examples` and `TestDatabaseCleanup.seeded_committed?`. Its new comment says the check is per example because an example or nested group can turn committed_data off.
- PR #389 adds two specs to `spec/db/committed_data_mode_spec.rb`. One checks that `reset_seeded_committed!` and `load_fresh_seed!` each run once. The other checks that a `committed_data: false` example in a seeded committed_data group counts 2 seeded companies.
- Review of PR #389 found the first version decided from group metadata. With that guard restored temporarily, the run gave 28 examples and 1 failure, `Expected 0 to eq 2`, in the new override spec. With the per-example guard, it gave 38 examples and 0 failures.
- PR #389 adds the `example_metadata` parameter to `spec/support/inner_example_through_suite_hooks.rb`.
