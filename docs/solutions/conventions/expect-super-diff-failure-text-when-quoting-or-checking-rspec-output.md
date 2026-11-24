---
module: spec
date: 2026-11-24
problem_type: convention
component: testing_framework
severity: low
audience: both
related_components:
  - documentation
tags:
  - rspec
  - super-diff
  - failure-output
  - removal-record
applies_when:
  - Quoting an RSpec failure in a document, pull request or issue
  - Reviewing whether a quoted RSpec failure is verbatim
---

# Expect super_diff failure text when you quote or check RSpec output

## Context

This repository's docs often quote the exact RSpec failure an example gave, for example when they record that an example fails once its mechanism is removed. The repository rule is "never fake results", so reviewers check that a quote is verbatim.

Stock RSpec prints an `eq` failure on separate lines: `expected:`, then `got:`, then `(compared using ==)`. This suite does not print that. It loads the `super_diff` gem, which prints one line such as:

`Expected [200, { "applied" => 1, "ignored" => 0 }] to eq [200, { "applied" => 0, "ignored" => 1 }].`

super_diff also puts spaces inside hash braces, which Ruby's own `Hash#inspect` does not do.

## Solution

- When you quote a failure, paste the line the run printed and name super_diff as its source. Then a reader who reruns the example knows what to look for.
- When you review a quote, do not flag the single-line `Expected ... to eq ...` form as a paraphrase. Compare it with super_diff output, or rerun the example.
- If you need stock RSpec output, turn super_diff off for that run. Check how `spec/spec_helper.rb` loads it before you rely on a switch for this.

## Why it matters

If a reviewer takes the stock RSpec format as the standard, a correct quote looks like an invented one. The author is then asked to replace real output with a paraphrase. Or the record gets reworded until it no longer matches what a rerun prints. Both make the record harder to trust, which is the opposite of what the review set out to do.

## Evidence

- PR #622 edits `docs/solutions/conventions/identify-the-lock-a-session-waits-on-not-only-that-it-is-blocked.md`. Its new **Projection version guard** subsection quotes `Expected [200, { "applied" => 1, "ignored" => 0 }] to eq [200, { "applied" => 0, "ignored" => 1 }].` from `spec/services/timekeeping/projection_consumer_spec.rb -e 'keeps v3 when a v2 delivery'`. The subsection says this is the super_diff matcher output that `spec/spec_helper.rb` loads.
- In this pull request's review, a reviewer said the quote was not RSpec's `eq` output. The author declined that finding. The author reran the example with the guard removed and got the same line. The author also searched the Gemfile and spec helpers for super_diff and found the `super_diff` gem in the Gemfile and a `require "super_diff/rspec"` in `spec/spec_helper.rb`.
- How to check this yourself: run `grep -n super_diff Gemfile spec/spec_helper.rb`.
