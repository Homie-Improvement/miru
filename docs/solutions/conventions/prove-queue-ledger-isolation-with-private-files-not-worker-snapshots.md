---
module: Timekeeping queue ledger
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - parallel_tests
  - RSpec subprocess tests
tags:
  - queue-ledger
  - test-isolation
  - concurrency
applies_when:
  - Testing ledger isolation while parallel workers can run
  - Adding unchanged-file assertions around a child test process
---

# Prove ledger isolation without observing active worker files

## Context

Do not compare active workers' ledger files before and after a child test process to prove isolation. Each worker owns its numbered file and deletes it at suite startup. That deletion can occur while the child runs.

A changed or missing worker file therefore does not establish that the child touched it. Even a read-only assertion can make an otherwise isolated test depend on another worker's timing.

## Solution

Keep the evidence inside a temporary directory owned by the test. For the numbered-default-path scenario, give the child `TIMEKEEPING_QUEUE_LEDGER_ROOT` and set `TIMEKEEPING_QUEUE_LEDGER_PATH` to `""`. This exercises numbered filenames without targeting real worker files.

Seed the parent's private ledger with known bytes. After the child exits, assert all three outcomes:

- The child exited successfully.
- The parent's private ledger still contains the seeded bytes.
- The expected child file, `tmp/timekeeping-integration/queue_ledger.99.json` under the private root, exists.

The last assertion matters because an unchanged parent file alone does not prove the child used the intended directory. A child that ignored the root would leave its expected private file absent.

## Why it matters

Snapshots of another worker's files combine two independent activities into one assertion. They can fail even when the child respects its private root. Checking existence before reading does not prevent deletion between those operations.

Private-file assertions preserve the isolation check without requiring other workers to stop changing their own state.

## Evidence

- PR #432, `spec/support/timekeeping/queue_ledger.rb`: the `ledger_path` comment states that each parallel process deletes its ledger at suite startup. The new root input redirects the numbered default path.
- PR #432, `spec/meta/timekeeping_queue_ledger_spec.rb`: the live private-root example checks child success, unchanged bytes in the parent's private file, and existence of the child's private `queue_ledger.99.json`. Its comment explains that ignoring the root would leave that file absent. The example does not snapshot real worker files.
