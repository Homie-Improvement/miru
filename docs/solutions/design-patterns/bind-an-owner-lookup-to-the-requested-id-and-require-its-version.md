---
module: Timekeeping gateway
date: 2026-10-26
problem_type: design_pattern
component: service_layer
severity: high
evidence_grounding: anchored
grounding_evidence: app/services/timekeeping/entry_lookup.rb find raises not_found unless found.entry.id matches entry_id, and timekeeping_entry raises EntryWriteClient::Error unless version is a non-negative Integer; spec/services/timekeeping/entry_lookup_spec.rb covers a 5152 answer for 5151 and versions nil, "3" and -1.
audience: both
related_components:
  - Timekeeping::EntryLookup
  - Timekeeping::EntryApiClient
  - Timekeeping::EntryWriteClient
tags:
  - optimistic-concurrency
  - if-match
  - authorization
  - lookup
applies_when:
  - An update or delete looks up its target in a remote or injected store before authorizing it
  - The write sends the looked-up version as If-Match
---

# Bind an owner lookup to the requested id and require its version

## Context

Before a forwarded update or destroy, `Timekeeping::EntryLookup` reads the entry from whichever store owns it. The policy authorizes that copy, and the write then targets `found.entry.id` with `If-Match: found.version`. The version check stops a change made after the policy check, such as an entry becoming billed.

Two guarantees the old code had for free are gone:

- `current_company.timesheet_entries.kept.find(params[:id])` could only return the requested row. A remote or local-owner answer can name a different id. The policy would then authorize that entry, and the write would change it.
- The provider accepts a request with no `If-Match` and skips the version check. A show answer without a `version` would produce a write with no header, so the concurrency guard switches off and nothing fails.

## Solution

- After any branch returns, refuse with not found unless the returned id equals the requested id and the company matches. Do this before authorization, for remote and local-owner answers alike.
- Accept a remote lookup only with a non-negative Integer `version`. Treat anything else as an unexpected answer (the retryable unavailable error), never as "no version".
- Test both with a client that answers a wrong id or a missing, string or negative version, and assert that no write follows.

## Why it matters

A wrong-id answer lets an authorized request change an entry the user never named. A missing version makes the If-Match protection look present in code and specs while doing nothing. Both pass every happy-path test.

## Evidence

In PR #170, `app/services/timekeeping/entry_lookup.rb` compares `found.entry.id.to_s == entry_id.to_s` and the company in `find`, and `timekeeping_entry` rejects a version that is not a non-negative Integer. `app/services/timekeeping/entry_write_client.rb` sets `If-Match` only `unless version.nil?`, which is why the lookup must refuse a missing version. `spec/services/timekeeping/entry_lookup_spec.rb` covers a show answer of 5152 for 5151, a local-owner answer of 6163 for 6161, and versions `nil`, `"3"` and `-1`. `spec/requests/api/v1/timesheet_entries/gateway_spec.rb` changes the entry between lookup and DELETE and expects 409 `version_conflict`, a kept entry, and an `If-Match` equal to the looked-up version.
