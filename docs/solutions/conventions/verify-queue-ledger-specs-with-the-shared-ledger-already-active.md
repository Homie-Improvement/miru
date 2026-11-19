---
module: Timekeeping proof harness
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: high
audience: both
related_components:
  - TimekeepingQueueLedger::Session
  - TestDatabaseCleanup
tags:
  - queue-ledger
  - test-isolation
  - cleanup-order
  - false-negative
applies_when:
  - Changing queue-ledger specs that create completed, claimed or failed Solid Queue rows
  - Changing cleanup used after the shared queue ledger has been activated
---

# Verify queue-ledger specs with the shared ledger already active

## Context

Check these specs after activating the shared ledger, not only in a fresh RSpec process.

The ledger records forbidden queue executions before cleanup deletes their database rows. Its own tests deliberately create those executions. A private `Session` isolates the test's verdict state, but not the database rows that the shared session observes.

A standalone spec run starts with the shared ledger inactive. Passing that run does not establish compatibility with a suite where an earlier runtime activated collection.

## Solution

Use two checks when changing these specs or their cleanup:

1. Activate `TimekeepingQueueLedger.session` before running the entire `spec/meta/timekeeping_queue_ledger_spec.rb` file. Give the process a temporary `TIMEKEEPING_QUEUE_LEDGER_PATH`. Keep the real cleanup hooks enabled. The examples must pass without adding their synthetic violations to the shared ledger.
2. While the shared ledger is active, create an unrelated completed `default` job in a `:without_transaction` example. Allow normal cleanup to run. Require the stored execution to survive cleanup and `finish!` to raise `TimekeepingQueueLedger::RunFailed`.

The first check detects interference from intentional fixtures. The second detects cleanup that hides real violations. An empty ledger alone does not distinguish correct isolation from deletion before observation.

Keep deliberate failure fixtures in `spec/fixtures/timekeeping_harness/queue_ledger_rows_probe.rb`, with private sessions and a private ledger path. Let normal cleanup remove their rows. Do not disable collection after a reset or add an unobserved truncate to make the parent specs pass.

The child process adds startup work. That cost preserves the shared ledger's meaning instead of making its own tests an exception to observation.

## Why it matters

These checks cover different failures. Counting synthetic executions makes a valid suite fail. Deleting executions before collection makes an invalid suite pass.

A passing run with an empty ledger proves neither property by itself. Test both fixture isolation and preservation of an unrelated violation whenever cleanup changes.

## Evidence

PR #393 adds suite-long activation in `spec/support/timekeeping/queue_ledger.rb`. Its regression example in `spec/meta/timekeeping_queue_ledger_spec.rb` checks later resets, teardown collection and the live-runtime refusal using a private session.

The same pull request moves deliberate database mutations into `spec/fixtures/timekeeping_harness/queue_ledger_rows_probe.rb`. The parent spec launches that fixture with a separate ledger path and expects seven passing examples.

The recorded activation-first verification completed 48 examples with 0 failures and 5 pending. Its shared ledger contained empty `records` and `controls` arrays. A separate cleanup verification retained a completed `UpdateInvoiceStatusToOverdueJob` execution and confirmed that `finish!` raised `RunFailed`; that verification completed one example with 0 failures.
