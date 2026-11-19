---
module: Timekeeping live specs
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - TimekeepingLiveInstance
tags:
  - rails-runner
  - code-injection
  - ownership-generation
  - timekeeping
applies_when:
  - A harness passes a caller-supplied value into a script run with rails runner
  - The same setting is used both in a runner script and in a request header
---

# Fill rails runner scripts from a checked Integer with a format string

## Context

`TimekeepingLiveInstance` admits an ownership generation by running a script through `bundle exec rails runner`. That script text runs as Ruby source. When the generation became a keyword (`admission_generation:`), any text a caller passed would have been executed by the child process. The same generation must also appear in the `Ownership-Generation` header that `write_entry` sends, or the admitted generation and the written generation disagree.

## Solution

Check the value once, at construction, before any child runs:

```ruby
unless admission_generation.is_a?(Integer) && admission_generation.positive?
  raise ArgumentError, "admission_generation must be a positive Integer"
end
```

Keep the script as a format string and fill it with `%d`, which only accepts a number:

```ruby
ADMIT_SCRIPT_FORMAT = <<~RUBY
  Timekeeping::Admission.ensure_initial!
  Timekeeping::Admission.admit!(generation: %d)
RUBY

run_in_service!(*RAILS, "runner", format(ADMIT_SCRIPT_FORMAT, @admission_generation))
```

Read the same stored value for the header: `post["Ownership-Generation"] = @admission_generation.to_s`.

## Why it matters

String interpolation into runner source is a code injection path, even in test support. A value like `"1); Kernel.exit(0"` would end the call early and run the rest as code. Checking the type and formatting with `%d` means only a number reaches the source. Reading one stored value for both the script and the header means the two cannot drift.

## Evidence

- PR #421 changes `spec/support/timekeeping/live_instance.rb`: `ADMIT_SCRIPT` becomes `ADMIT_SCRIPT_FORMAT` with `%d`, `initialize` raises `ArgumentError` unless the generation is a positive Integer, and `write_entry` sends `@admission_generation.to_s`.
- `spec/meta/timekeeping_live_instance_spec.rb` checks that `"2"`, `"1); Kernel.exit(0"`, `0`, `-1`, `2.5` and `nil` each raise `ArgumentError` with no call to `Open3.capture2e` or `Process.spawn`, and that generation 2 yields a runner script containing `admit!(generation: 2)` and a header of `2`.
