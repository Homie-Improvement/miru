---
module: timekeeping
date: 2026-11-17
problem_type: design_pattern
component: timekeeping_handoff
severity: medium
audience: both
related_components:
  - timekeeping_gateway
  - entry_write_client
tags:
  - idempotency
  - uuid-v5
  - key-collision
  - receipts
  - cutover
applies_when:
  - Minting idempotency keys for receipts the system creates itself, beside keys derived from client input
  - The target receipt store scopes receipts by fewer columns than the source store
---

# Derive carried idempotency keys from a dedicated UUID namespace

## Context

The first cutover carries legacy create receipts into Timekeeping under a key the system makes up. An ordinary forwarded create gets its key from `EntryWriteClient.idempotency_key(request_id:, operation:)`, seeded with the client's Idempotency-Key exactly as sent.

The first design built the carried key with that same function, seeded with `"legacy_create/#{actor_kind}/#{key}"`. A client that sent `legacy_create/user/K` as its own key then derived the very UUID of its carried receipt for `K`. This change does not show how Timekeeping answers such a request. Going by the change's comments, it would presumably answer it from the old receipt: a false replay of an old entry, or a 422.

There is a second trap. Legacy receipts are unique per company, actor kind, actor and key. The `carried_key` comment in `legacy_create_replay.rb` states that Timekeeping scopes receipts by company, user and key only, and the runner spec's stub models it that way. This is an assumption about Timekeeping that the change does not demonstrate. A browser create and a command-line create made with one client key are two separate legacy receipts. Under that assumed scope, without actor kind in the key they would share one Timekeeping receipt, and one of the two retries would be refused. The change shows only the other side: with distinct carried keys, both retries replay against the stub.

## Solution

- Give system-made keys their own fixed UUID v5 namespace, different from the client-key function's namespace: `Digest::UUID.uuid_v5(CARRIED_KEY_NAMESPACE, "#{actor_kind}/#{key}")`. No client string can produce a value in that namespace through the ordinary path.
- Put every source scope column the target store lacks into the hashed name. Here that column is `actor_kind`.
- Have both sides call one function, `LegacyCreateReplay.carried_key`: the conversion that writes the checkpoint row, and the gateway that resends the retry.
- Pin the property in a spec: crafted client keys shaped like the seed (`legacy_create/user/K`, `user/K`, and the `cli` forms) must not derive any carried key.

## Why it matters

A prefix only separates two key spaces when no outside party can choose the prefix. Client keys are free text, so a prefix inside a shared hash gives no isolation. A separate namespace does give it. Folding the missing scope columns into the key also means every source receipt keeps a distinct receipt in the target store, so no legitimate retry is lost.

## Evidence

- PR #351, `app/services/timekeeping/legacy_create_replay.rb`: adds `CARRIED_KEY_NAMESPACE` and `carried_key`, which uses `Digest::UUID.uuid_v5` over `"#{actor_kind}/#{key}"`. The comments name both reasons: client keys cannot reach it, and actor kind keeps browser and command-line receipts apart because Timekeeping scopes receipts by company, user and key only. That scope is stated in the comment, not tested against Timekeeping itself.
- PR #351, `spec/services/timekeeping/legacy_create_replay_spec.rb`: one example checks that `user` and `cli` carried keys differ from each other and from the ordinary forwarded key. Another checks that crafted seed-shaped client keys derive no carried key.
- PR #351, `lib/timekeeping/legacy_create_receipt_conversion.rb` and `app/services/timekeeping/gateway.rb` (`forward_carried_create`) both call `LegacyCreateReplay.carried_key`.
- PR #351, `spec/lib/timekeeping/handoff/runner_legacy_create_replay_spec.rb`: against a stub that looks receipts up by company, user actor, operation and key, a browser create and a command-line create under one client key each replay their own entry after the cutover.
- During review of PR #351, a runner check compared `carried_key(actor_kind: "user", key: "K1")` with the ordinary key derived from `legacy_create/user/K1`. It returned two different UUIDs.
