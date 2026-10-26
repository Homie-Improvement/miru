---
module: timekeeping_relay
date: 2026-10-26
problem_type: design_pattern
component: timekeeping_relay
severity: high
evidence_grounding: anchored
grounding_evidence: "In PR #53, gems/timekeeping_relay/lib/timekeeping_relay/relay.rb canonicalizes the batch before taking IdempotencyKey.for(batch); idempotency_key.rb hashes BatchJson.generate(BatchJson.canonical(batch)); http_endpoint.rb posts BatchJson.generate(batch); fake_relay_adversarial_spec.rb and batch_json_spec.rb prove the two-source and reordered-retry cases."
audience: both
related_components:
  - timekeeping
  - entry_snapshots
tags:
  - idempotency-key
  - outbox
  - relay
  - at-least-once
  - canonical-json
applies_when:
  - A relay posts outbox batches with an Idempotency-Key to a consumer that stores and replays answers by key
  - More than one outbox source, each with its own position sequence, posts to the same consumer under one credential
  - A source can rebuild the same row with its hash keys in a different order
---

# Derive relay idempotency keys from the canonical batch that is actually posted

## Context

The snapshot relay in `gems/timekeeping_relay` sends outbox rows at least once. It marks rows sent only after a 200. If the mark is lost, the next run resends the same rows. The consumer of `POST /internal/v1/timekeeping/entry-snapshots` handles that with an Idempotency-Key. For a key it knows, it replays its stored first answer. For a known key whose body differs, it refuses the request as a reused key.

The first plan built the key from outbox positions alone. That breaks in two ways:

- Each application numbers its own outbox. A Timekeeping batch at position 1 and a monolith batch at position 1 get the same key with different entries. The consumer either replays the first batch's 200 for the second (its rows are marked sent but never applied) or refuses it as a reused key. A refused batch stops an in-order relay for good.
- A later fix sorted hash keys before hashing, but the HTTP adapter still posted the unsorted hash. A source that rebuilt a row with its keys in another order then sent a body whose text differed from the first try under the same key. The retry after a lost mark was refused.

## Solution

Use one canonical form for both the key and the body:

1. `TimekeepingRelay::BatchJson.canonical` turns hash keys into strings and sorts them at every depth.
2. `Relay#deliver` canonicalizes the batch once: `batch = BatchJson.canonical(batch_for(rows))`. It then passes that same object to `IdempotencyKey.for(batch)` and to `endpoint.deliver`.
3. `IdempotencyKey.for` is a version 5 UUID over `BatchJson.generate(BatchJson.canonical(batch))`, so it covers generation, position and the full entry.
4. `HttpEndpoint#post` writes the body with the same `BatchJson.generate`.

Outbox rows are never rewritten, so a resend of the same rows gives the same text and the same key, and the consumer replays its stored answer. The same rows inside a different batch (with newer rows added) get a new key. The consumer applies them again and counts the old ones as `ignored`.

## Why it matters

With an in-order relay that never skips a row, a wrong key does more than cause one failed POST. Either rows are marked sent without being applied, which loses data silently, or one batch is refused forever and every later row for every company waits behind it. Neither shows up in a single-source happy-path test. Test with two sources that share positions, and with a lost mark followed by a retry of a reordered row.

Keep a single serializer for the key and the body. If they use different serializers, any difference in key order, float format or nesting options is enough to make a retry look like a reused key.

## Evidence

- PR #53, head commit 9ef7b6dc7f130b83f8d90298af8b198776900b62.
- `gems/timekeeping_relay/lib/timekeeping_relay/batch_json.rb`: its comment says the consumer fingerprints the body and refuses a reused key whose body differs, so the key must come from exactly the posted text.
- `gems/timekeeping_relay/lib/timekeeping_relay/idempotency_key.rb`: its comment explains why positions alone are not enough, and the key is hashed from the canonical JSON.
- `gems/timekeeping_relay/lib/timekeeping_relay/relay.rb` canonicalizes the batch before the key is taken. `gems/timekeeping_relay/lib/timekeeping_relay/http_endpoint.rb` posts `BatchJson.generate(batch)`.
- `gems/timekeeping_relay/spec/timekeeping_relay/fake_relay_adversarial_spec.rb`: two sources with equal positions and different entries both reach the fake projection.
- `gems/timekeeping_relay/spec/timekeeping_relay/batch_json_spec.rb`: after a lost mark, a retry of the row rebuilt with reversed entry keys gets 200 twice and is marked sent.
- `gems/timekeeping_relay/spec/timekeeping_relay/idempotency_key_spec.rb`: reordered input gives the same key, and a changed generation, version or entry id gives a different key.
