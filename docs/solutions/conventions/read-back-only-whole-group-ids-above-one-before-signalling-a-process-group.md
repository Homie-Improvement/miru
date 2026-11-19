---
module: spec/support/timekeeping
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: high
audience: both
related_components:
  - lib/timekeeping_demo
tags:
  - process-group
  - process-kill
  - teardown
  - pid-file
applies_when:
  - Teardown reads process or group ids from a file and passes them to Process.kill
  - A launcher records child group ids so a caller can stop them after the launcher dies
---

# Read back only whole group ids above 1 before signalling a process group

## Context

`TimekeepingDemo::Supervisor` starts each app with `pgroup: true`, so the app groups keep running if the launcher is killed. With `groups_path:` set, the supervisor appends each group id to `tmp/timekeeping-demo/process_groups` right after each spawn. Teardown in `IntegratedRuntime` reads that file and calls `Process.kill("KILL", -group)`.

The file is written by a process that may be killed at any moment. A negative pid targets a group, and two values are dangerous: `Process.kill(sig, -0)` signals the caller's own group (the test runner), and `-1` signals every process the user owns. A blank line becomes 0 through `"".to_i`. A torn last line such as `424` of `4242` can name a group this harness never started.

## Solution

Write each id with a newline and flush it at once:

```ruby
File.open(@groups_path, "a") do |file|
  file.puts(group)
  file.flush
end
```

Read back only lines that ended in a newline, contain only digits, and are 2 or more:

```ruby
GROUP_LINE = /\A\d+\z/
SMALLEST_GROUP = 2

text.each_line.filter_map { |line| line.chomp if line.end_with?("\n") }
    .grep(GROUP_LINE).map { |line| Integer(line, 10) }.select { |id| id >= SMALLEST_GROUP }
```

Empty the file only after the live-group check passes. Old ids can be reused by unrelated processes, and teardown must never signal them.

## Why it matters

A parsing slip here does not fail a test. It kills the test runner or the developer's whole session. The newline rule turns a write that was cut off into a skipped line instead of a wrong id.

## Evidence

- PR #378 adds `record_group` to `lib/timekeeping_demo/supervisor.rb` and calls it after each spawn in `prepare` and `run`.
- `spec/support/timekeeping/integrated_runtime.rb` adds `parse_groups` with `GROUP_LINE` and `SMALLEST_GROUP`, and `clear_leftovers!`, whose comment explains why old ids are cleared only after `refuse_if_running!`.
- `spec/lib/timekeeping_demo/integrated_runtime_spec.rb` expects `parse_groups("4242\n\n0\n1\n-7\nabc\n12x\n 99\n31337\n5")` to equal `[4242, 31_337]`, skipping the final `5` that has no newline.
- `spec/lib/timekeeping_demo/supervisor_spec.rb` checks that each id is on disk before the next `Process.spawn` call.
