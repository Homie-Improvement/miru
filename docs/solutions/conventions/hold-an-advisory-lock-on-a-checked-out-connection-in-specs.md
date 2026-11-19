---
module: timekeeping relay
date: 2026-11-19
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - background_job
  - database
tags:
  - advisory-lock
  - postgres
  - relay
  - connection-pool
applies_when:
  - A spec must prove code does nothing while a pg_advisory_lock it needs is held elsewhere
  - The code under test takes the lock on ActiveRecord::Base.connection, for example Timekeeping::RelayJob with RELAY_LOCK_KEY
---

# Hold an advisory lock on a checked-out connection in specs

## Context

A Postgres advisory lock belongs to a session, which is one database connection. If a session already holds the lock, it can take it again without waiting. In a spec, the code under test usually runs on `ActiveRecord::Base.connection`. If the spec takes the lock on that same connection, the code takes it again and runs normally. A spec meant to show "the relay sends nothing while the lock is held" then shows nothing.

## Solution

Check out a second connection, take the lock there, and release it in `ensure`:

```ruby
holder = ActiveRecord::Base.connection_pool.checkout
begin
  holder.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT pg_advisory_lock(?)", key]))
  drain.drain!(through: p_position)
  expect(drain.drained?(through: p_position)).to be(false)
ensure
  holder.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT pg_advisory_unlock(?)", key]))
  ActiveRecord::Base.connection_pool.checkin(holder)
end
```

After the lock is released, run the code again and check that it now succeeds. That proves the lock, and nothing else, was what stopped it.

## Why it matters

If the lock is on the wrong connection, the spec cannot fail, so the code path that handles a busy lock is never tested. In `RelayDrain`, that path is why `drain!` returning means nothing. A relay that cannot take its lock returns without sending, and only `drained?` reads the stored `sent_at` state. Unlock and checkin go in `ensure` so a failed expectation does not leave the lock held or the connection checked out for later examples.

## Evidence

- PR #401 adds the example "with the relay advisory lock held drained? stays false after drain! returns" in `spec/lib/timekeeping/handoff/relay_drain_spec.rb`. It takes `Timekeeping::RelayJob::RELAY_LOCK_KEY` on a connection from `ActiveRecord::Base.connection_pool.checkout`. A comment there says the holding session can take the lock again, so holding it on the relay's own connection would not stop the relay.
- The same example checks that `row.reload.sent_at` is nil while the lock is held, and that `drained?` is true after unlock and a second `drain!`.
- `lib/timekeeping/handoff/relay_drain.rb` says in its class comment that a relay which could not take its lock returns without sending.
