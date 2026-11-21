---
module: timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - two_tenant_seed
tags:
  - aggregate-failures
  - rspec
  - multi-company
  - polling
applies_when:
  - One example loops over several seeded companies inside aggregate_failures
  - A step in the loop can raise rather than fail an expectation, such as a bounded poll
---

# Rescue raised errors per company inside an aggregate_failures loop

## Context

Live examples boot the runtime and run a cutover, and that takes minutes. So one example loops over `fork_and_leaf` and `copper_kettle` inside `aggregate_failures`. The goal is that a failure for one company never hides the result for the other.

`aggregate_failures` collects only failed expectations. A raised error, such as `TimekeepingSection93Live::PollTimeout` from a bounded poll, still ends the block at once. Then the second company is never checked.

## Solution

Rescue the known raised error inside each loop step. Record it as a failed expectation that names the company:

```ruby
section_9_3_companies.each do |name, company|
  yield name, company
rescue TimekeepingSection93Live::PollTimeout => timeout
  expect(timeout).to be_nil, "#{name}: #{timeout.message}"
end
```

Rescue only the errors you expect, such as a poll timeout. An unexpected error should still stop the example.

## Why it matters

Without the rescue, one company's timeout looks like the only problem. A second, different regression for the other company goes unseen until the next slow run.

## Evidence

- PR #541 adds `section_9_3_each_company` in `spec/integration/timekeeping/section_9_3_spec.rb`. Its comment explains that `aggregate_failures` collects only failed expectations, so the helper records a poll timeout as one.
- `section_9_3_poll_until` in `spec/support/timekeeping/section_9_3_live.rb` raises `PollTimeout` with what it waited for and the last value it saw.
