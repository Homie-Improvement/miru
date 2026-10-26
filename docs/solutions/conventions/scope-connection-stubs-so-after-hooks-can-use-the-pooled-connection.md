---
module: spec/support
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "PR #156 removes ledger_cleanup_connection from spec/support/database_cleaner.rb, wraps the preflight stub in RSpec::Mocks.with_temporary_scope in spec/lib/timekeeping/preflight_spec.rb, and adds allow(connection).to receive(:execute).and_call_original before the SELECT 1 stub in spec/requests/health_spec.rb. A new test in spec/requests/health_spec.rb runs the stubbed example through the real hooks and sees both ledger DELETEs pass through the stubbed connection."
audience: both
related_components:
  - spec/support/database_cleaner.rb
  - spec/support/inner_example_through_suite_hooks.rb
tags:
  - rspec-mocks
  - connection-stub
  - after-hooks
  - test-cleanup
  - with-temporary-scope
applies_when:
  - An example stubs ActiveRecord::Base.connection or a method on the pooled connection
  - A suite after hook runs SQL on ActiveRecord::Base.connection
  - Someone proposes a separate adapter in spec/support to avoid example stubs
---

# Scope connection stubs so after hooks can use the pooled connection

## Context

The suite runs a final `config.append_after` hook, `TestDatabaseCleanup.delete_operation_ledger_rows!`. It deletes invoice operation intents and outbox items that another connection committed. Without it, those rows survive the rollback of the example's transaction.

An rspec-mocks stub does not end when the example body ends. It stays active until the after hooks finish. Two examples broke the cleanup this way:

- `spec/lib/timekeeping/preflight_spec.rb` made `ActiveRecord::Base.connection` raise for the whole example.
- `spec/requests/health_spec.rb` stubbed `execute` only with `"SELECT 1"`. rspec-mocks then refuses any `execute` call with other arguments, so the hook's DELETE statements failed.

The earlier fix built and cached a second adapter outside the pool, `ledger_cleanup_connection`. That fix put extra connection handling into shared test code only to get around two stubs.

## Solution

Limit each connection stub to the call it tests. Then shared cleanup uses `ActiveRecord::Base.connection` like any other code:

```ruby
def delete_operation_ledger_rows!
  connection = ActiveRecord::Base.connection
  connection.execute("DELETE FROM invoice_operation_outbox_items")
  connection.execute("DELETE FROM invoice_operation_intents")
end
```

There are two ways to limit a stub, depending on what the example proves.

**The example proves code never touches the database.** Put the stub and the call inside `RSpec::Mocks.with_temporary_scope`. rspec-mocks removes the stub when the block returns, before the after hooks run:

```ruby
result = RSpec::Mocks.with_temporary_scope do
  allow(ActiveRecord::Base).to receive(:connection).and_raise("classify must not touch the database")

  classify_one(preflight_entry(1, locked: true), [preflight_link(1, 10)])
end
```

Keep the stub on `connection` itself. Do not swap it for a check on `sql.active_record` events. Code can check out a connection without running any SQL, and an event check would not see that.

**The example makes one query fail.** First declare a general stub that passes calls through. Then declare the narrow one. rspec-mocks tries the most recent matching stub first, so only `SELECT 1` raises:

```ruby
allow(connection).to receive(:execute).and_call_original
allow(connection).to receive(:execute).with("SELECT 1").and_raise(StandardError, "database unavailable")
```

To prove what an after hook does under a stub, run an inner example through the real hooks with `run_inner_example_through_suite_hooks` from `spec/support/inner_example_through_suite_hooks.rb`. A single example cannot see its own after hooks from inside itself.

## Why it matters

If a stub stays active for the whole example, the next author is tempted to add another private connection to spec support. That connection is never disconnected. It cannot see rows inside the example's open transaction. Every later contributor also has to learn that cleanup takes a different path from every other test step. A scoped stub keeps the example's assertions and leaves the shared hooks alone.

When you review a new example that stubs `ActiveRecord::Base.connection` or `execute`, check that the stub is scoped as shown above. If it is not, the last after hook fails in that example, and the failure points to the cleanup code instead of the stub.

## Evidence

- PR #156, `spec/support/database_cleaner.rb`: deletes `ledger_cleanup_connection` (the cached `db_config.adapter_class.new(db_config.configuration_hash)` adapter) and the comment about stubs, and runs both deletes on `ActiveRecord::Base.connection`.
- PR #156, `spec/lib/timekeeping/preflight_spec.rb`: the "reads no database" example now wraps its `receive(:connection).and_raise` stub and the `classify_one` call in `RSpec::Mocks.with_temporary_scope`. It keeps the `expect(result[:active]).to eq([1])` assertion.
- PR #156, `spec/requests/health_spec.rb`: adds `allow(connection).to receive(:execute).and_call_original` before the `.with("SELECT 1")` stub. It also adds an example that runs through the suite hooks, gets 503 "unhealthy", and sees both `DELETE FROM invoice_operation_outbox_items` and `DELETE FROM invoice_operation_intents` pass through the stubbed connection.
- PR #156, `spec/db/committed_data_mode_spec.rb`: new examples check that both ledger deletes run on the pooled connection, outbox items first. They also check that no intent or outbox rows remain when counted from a second connection after the hooks run.
- PR #156, `spec/support/inner_example_through_suite_hooks.rb`: the shared runner that both spec files use to run an inner example through the registered hooks.
