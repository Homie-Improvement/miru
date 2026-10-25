---
module: Timekeeping contracts
date: 2026-10-25
problem_type: convention
component: testing_framework
severity: high
evidence_grounding: anchored
grounding_evidence: "PR #27 contracts/timekeeping/entry_api.yml rules.credential_in_body and errors.credential_in_body (422); fake_timekeeping.rb credential_in_body policy searches the JSON body for held credentials; mutation_spec.rb rows 'copies a credential into proof_metadata' and 'accepts an entry body that carries a credential'."
audience: both
related_components:
  - TimekeepingContract::FakeTimekeeping
  - entry snapshots
  - entry API
tags:
  - timekeeping
  - credentials
  - snapshots
  - proof-metadata
applies_when:
  - A published event must carry no credential but includes free-form JSON fields
  - Implementing an entry API or snapshot producer for the Timekeeping contracts
---

# Refuse credentials at the write, not by checking snapshot keys

## Context

The entry snapshot must carry no name, email or credential. `entry_snapshots.yml` lists the exact allowed keys, and the shape examples reject any extra key. That catches an added `user_email` field.

It does not catch a token placed inside an allowed field. `source_metadata` and `proof_metadata` hold any keys the caller sends. The snapshot is the whole row, so the producer published those values unchanged. A body such as `proof_metadata: { "token" => <bearer token> }` passed every key check.

## Solution

Use two checks, each for its own leak:

1. Keep the exact key-set check. It stops new fields such as names and emails.
2. Refuse the write at admission. An entry create or update whose body holds a credential the provider issued or holds (a user token or a service identity), at any depth, answers `422 credential_in_body` and changes nothing. No snapshot can then carry it.

Refuse the write rather than scrub the snapshot. Scrubbing would make the projected row differ from the stored entry, and the snapshot contract says the two match.

Prove it with a deep search, not key checks. Serialize the whole published batch and assert that it contains no token or service identity used in the example. Also add a broken fake that copies a credential into `proof_metadata`. It must fail.

## Why it matters

An exact key list feels like it already covers credentials. The README's "Exact keys" section still names a token as an example of a forbidden key. A provider that relies on that check alone passes the shape examples and can still forward a caller's bearer token to every consumer of the projection.

## Evidence

PR #27, head commit `e485f7ac3333e22641e2f9b2da540f6276e55698`:

- `contracts/timekeeping/entry_api.yml`: `rules.credential_in_body` and `errors.credential_in_body` (status 422).
- `spec/support/timekeeping/fake_timekeeping.rb`: the `credential_in_body` policy runs `JSON.generate(body)` and checks it for every held credential. `entry_request` returns the error before any write.
- `spec/contracts/timekeeping/entry_api_examples.rb`: the "credentials in an entry body" examples nest a token or service identity in `source_metadata` and `proof_metadata` on create and update, and expect nothing to change.
- `spec/contracts/timekeeping/entry_snapshot_examples.rb`: "carries no credential anywhere in the batch, nested metadata included" searches the serialized batch.
- `spec/contracts/timekeeping/mutation_spec.rb`: the rows "copies a credential into proof_metadata" and "accepts an entry body that carries a credential" must each fail their group.
- `contracts/timekeeping/README.md`: the "Exact keys" section still names a token as something the key list rejects.
