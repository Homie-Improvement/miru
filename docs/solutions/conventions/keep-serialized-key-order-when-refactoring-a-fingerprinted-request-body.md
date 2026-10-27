---
module: timekeeping
date: 2026-10-27
problem_type: convention
component: service_layer
severity: high
evidence_grounding: anchored
grounding_evidence: "PR #223: timekeeping/app/services/timekeeping/entry_command.rb hashes JSON.generate(body) for the fingerprint, and spec/services/timekeeping/entry_write_client_spec.rb pins the exact serialized web create body with source keys last"
audience: both
related_components:
  - api_layer
tags:
  - idempotency
  - fingerprint
  - json-key-order
  - forwarded-writes
  - timekeeping
applies_when:
  - Changing a builder whose output is sent with an Idempotency-Key to the Timekeeping service
  - Reordering hash merges in any request body the receiver fingerprints as serialized text
---

# Keep serialized key order when refactoring a fingerprinted request body

## Context

Timekeeping stores an idempotency receipt for each write. A retry with the same key must send the same body to get the stored answer back. Timekeeping decides "same body" by hashing the body as serialized text: `EntryCommand.build` sets `fingerprint: Digest::SHA256.hexdigest(JSON.generate(body))`. `JSON.generate` writes keys in hash insertion order. So two bodies with equal fields but a different key order get different fingerprints. The retry is then refused as `idempotency_key_reused` instead of getting the committed answer.

In PR #223, `EntryWriteClient.create_body` was generalised to take an `actor_kind`. The first version merged the source defaults in a different position. The web create body then serialized `source` and `source_metadata` in a new place. A web or mobile create committed before the deploy and retried after it would have been refused.

## Solution

- Treat the serialized key order of a fingerprinted body as part of its wire format. Keep it when you refactor the builder.
- To let a caller's value override a default without moving the key, merge the defaults last with a block that keeps the given value:

  ```ruby
  forwarded_fields(attributes, actor_kind:, operation: :create)
    .merge("project_id" => project.id, "user_id" => user.id)
    .merge(CREATE_SOURCE.deep_dup) { |_key, given, _default| given }
  ```

  `Hash#merge` keeps an existing key in its original position. A writer's own `source` stays where it was and wins. For the web writer, the defaults are still appended last, as before.
- Pin the order with a test that compares the `JSON.generate` string, not the hash. Comparing hashes with `eq` or `include` ignores order.

## Why it matters

A wrong key order shows up in no unit test that compares hashes, and in no single-request test. It shows up only as refused retries for requests that straddle a deploy, which are the retries idempotency keys exist for. The caller gets a 422 for a write that already committed.

## Evidence

- PR #223, `app/services/timekeeping/entry_write_client.rb`: the `create_body` comment says Timekeeping fingerprints the body as serialized, key order included. It merges `CREATE_SOURCE` last with a block that keeps given values.
- PR #223, `timekeeping/app/services/timekeeping/entry_command.rb`: the fingerprint is `Digest::SHA256.hexdigest(JSON.generate(body))`.
- PR #223, `spec/services/timekeeping/entry_write_client_spec.rb`: the example "serializes a web create body with the default source keys after project_id and user_id" compares the exact `JSON.generate` output. "keeps a cli create's own source values over the defaults" checks that the override still works.
- The code review on PR #223 found this regression. The author's check compared the base and head serializations for the same input and found them equal once the fix was in.
