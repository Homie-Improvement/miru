---
module: spec/support
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/meta
  - solid_queue
tags:
  - database-cleaner
  - source-scan
  - meta-spec
  - queue-ledger
  - test-database-cleanup
applies_when:
  - A safety step, such as recording queue executions, must run before every reset of the monolith test database
  - Adding or editing a rule in spec/meta/test_database_cleanup_reset_sites_spec.rb
  - Writing any spec-wide source scan that must catch call sites added in the future
---

# Enforce a single reset wrapper with an exact-count source scan

## Context

Before a monolith reset deletes rows, `TestDatabaseCleanup.before_reset!` records the Solid Queue executions that the delete would erase. Until this change, that order held only because each reset site paired the two calls by hand. If a new site left out the call, executions were lost with no record, and no test failed: the ordering tests cover only the sites that already exist.

A wrapper alone does not stop someone from writing a new raw `TRUNCATE`. The only check that covers code written later is a scan of the source.

## Solution

1. Give the safe sequence one entry point. `TestDatabaseCleanup.clean_with!(strategy, **options)` calls `before_reset!` and then passes the strategy and options to `DatabaseCleaner.clean_with` unchanged. Every monolith reset calls it.
2. Keep the scan's rules as data. `TestDatabaseCleanupResetSiteScan::RULES` is a frozen list of `Rule` values (`name`, `pattern`, `allowed`, `only_in`). `allowed` maps a file to the exact number of matching lines it may hold. Each allowance has a comment that gives its reason.
3. Keep the scanner pure. `offenses(sources)` takes a hash from path to text and returns `"rule: path:line"` strings. You can test it with synthetic sources, and one example runs it over `spec/**/*.rb`.
4. Check each allowance in both directions. One example asserts that each allowed file holds *exactly* its allowed count. Without that check, if an allowed site is deleted, a new unsafe site can take its slot and the scan stays green.
5. Match statements, not physical lines:
   - `statements` joins a line that starts with `.` onto its receiver's line, unless that line is a comment. A chain split across lines, such as `SolidQueue::Job.where.not(finished_at: nil)` with `.delete_all` on the next line, is then reported at the receiver's line.
   - The raw-truncate pattern also counts a `TRUNCATE` that ends its line. SQL heredocs often put the table names on the next line.
   - The pattern accepts only a `TRUNCATE` that opens a string or a heredoc line. Ruby names such as `truncate_tables(connection)`, `:truncate` and `"truncates long names"` are not counted.
6. For each rule, add a synthetic example that must be reported. Each one should fail if its pattern is removed.

## Why it matters

The failure this guards against is silent: the suite passes and the queue ledger is missing executions. A scan that matches one physical line at a time looks complete, but it misses the two most common ways to write a multi-line reset. An allowance written as a maximum, rather than an exact count, decays as files change. Keeping allowances only in `RULES` means one edit changes the policy. Before this was fixed, a second hand-written copy had already drifted from `RULES` in how it handled comment lines.

## Evidence

- PR #418 adds `spec/meta/test_database_cleanup_reset_sites_spec.rb`, which contains `RULES`, `offenses`, `statements` and the example "finds exactly the allowed number of matches in each allowed file".
- The same file has regression examples for a split `SolidQueue::Job` delete chain and for a heredoc and a quoted string with `TRUNCATE` alone on its line. Review of this pull request raised both forms. After the fixes, the author's recorded runs of that spec passed with 17 examples and then 18 examples, with 0 failures.
- `spec/support/database_cleaner.rb` defines `clean_with!`. The sites in `spec/support/committed_data.rb`, `spec/support/two_tenant_seed.rb` and `spec/timekeeping/runtime_queues_spec.rb` now call it in place of the hand-paired calls.
