---
module: timekeeping
date: 2026-11-24
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - Timekeeping::LocalOwner::WriteSteps
  - Timekeeping::WriteSteps
tags:
  - advisory-lock
  - pg-locks
  - concurrency-specs
  - lock-removal
applies_when:
  - A spec must prove a session waits on a particular pg_advisory_xact_lock taken with two int4 keys
  - The product helper computes the key and takes the lock in one call
---

# Match a two-key advisory lock in pg_locks by recorded keys, read as unsigned oids

## Context

A concurrency spec can show that one session is blocked by another and still pass with the lock under test removed. Another wait, such as a unique index on a receipt, can block the same session instead. To prove the right lock, the spec must find that exact advisory lock in `pg_locks`.

Two things get in the way. Neither `LocalOwner::WriteSteps.lock_key` nor the Timekeeping `WriteSteps.lock_key` returns its key halves. Each one computes the key and takes the lock right away. So the spec cannot call them to learn the key: on the observer connection, that call would itself wait behind the writer. Also, `pg_locks` does not list the keys as the signed integers the code passed in.

## Solution

Record the keys at the point where the product already takes the lock, with `and_wrap_original`. The product still takes the lock itself:

```ruby
allow(write_steps).to receive(:advisory_lock).and_wrap_original do |method, *keys|
  recorded << keys if Thread.current[:legacy_create_lock]
  method.call(*keys)
end
```

A wrap on `lock_key` sets the thread-local flag only for the `LEGACY_CREATE_LOCK` call. This keeps other advisory locks out of the recorded keys.

Then read `pg_locks` on a connection opened outside the pool. A two-key `pg_advisory_xact_lock` appears with the first key in `classid`, the second key in `objid`, and `objsubid = 2`. Both columns are unsigned 32-bit oids, so mask each key first:

```ruby
high, low = keys.map { |key| key & 0xFFFF_FFFF }
# ... WHERE pid = ? AND locktype = 'advisory' AND objsubid = 2 AND NOT granted
#     AND classid::bigint = high AND objid::bigint = low
```

In some cases you can record the arguments to `lock_key` but not the keys it builds. The Timekeeping bundle is one example. There, join a waiting advisory row against a granted one held by the other session on the same `classid` and `objid`. Then take the waiter's last recorded `lock_key` parts to name the lock.

## Why it matters

Without the mask, a negative key never matches its `pg_locks` row. The assertion then fails on a correct tree. If you call the product's key helper from the observer, the check blocks behind the session it is observing. Rebuilding the key digest inside the spec is a second copy of the product's rule, and the two can drift apart. Recording the real keys avoids all three problems.

## Evidence

PR #618 adds `record_legacy_create_lock_keys` and `legacy_create_lock_wait?` to `spec/services/timekeeping/gateway_spec.rb`. Their comments state the `classid`/`objid`/`objsubid = 2` layout and the two's-complement listing of negative keys, and the code masks each key with `key & 0xFFFF_FFFF`. With the `LEGACY_CREATE_LOCK` call removed, the strengthened example failed on this check. The removal record in `docs/solutions/conventions/identify-the-lock-a-session-waits-on-not-only-that-it-is-blocked.md` quotes that failure. Before the change, the same removal went red only through `ActiveRecord::RecordNotUnique`, because the retry still waited on the receipt's unique index. The same pull request adds `record_detach_lock_parts` and `agent_waits_on_advisory_lock_held_by?` to `timekeeping/spec/services/timekeeping/entry_writer_race_spec.rb`, which use the waiting-to-holding join form.
