---
module: imports
date: 2026-10-27
problem_type: design_pattern
component: service_layer
severity: high
evidence_grounding: anchored
grounding_evidence: "app/services/imports/harvest_time_entries_importer.rb in PR #208 defines ROW_KEY_FIELDS without currency, user, project or bill status, and the importer spec covers reruns after a base currency change and after the project turns non-billable"
audience: both
related_components:
  - timekeeping_gateway
  - entry_write_client
tags:
  - idempotency-key
  - imports
  - rerun
  - harvest
applies_when:
  - A batch job forwards rows to a remote store and can be rerun after it fails partway
  - The retry key is a digest of the row
---

# Derive rerun idempotency keys from raw file values, not workspace lookups

## Context

The Harvest importer forwards each CSV row to Timekeeping with an `Idempotency-Key`. That key lets Timekeeping recognise a rerun of the same row and replay the stored entry instead of creating a second one. A rerun of a failed import runs under a new random request id, so the key must come from the row itself.

The trap is that the importer's "row" is not only the file. Normalization resolves the user, the project, the bill status (from the project's current `billable` flag) and the currency. When the file has no Currency column, the currency falls back to the company's base currency. Any of these can change between a failed run and its rerun. A key hashed over them gives an already-written row a new key, and Timekeeping stores it twice when the local copy of that entry has not arrived yet.

## Solution

Build the key only from values that cannot change between runs:

- the data import id,
- the row's CSV line number (so two identical lines stay two entries),
- the raw values read from the uploaded file.

In `Imports::HarvestTimeEntriesImporter` this is `ROW_KEY_FIELDS`:

```ruby
ROW_KEY_FIELDS = %i[
  row date client_name project_name project_code user_name hours billable invoiced note hourly_rate
].freeze
```

`row_idempotency_key` takes a SHA-256 digest of those fields and turns `"harvest-import/#{data_import.id}/#{digest}"` into a version 5 UUID.

When workspace state did change, the rerun sends the same key with a different body. Timekeeping refuses a reused key with a different body (`Timekeeping::EntryWriteClient::Rejected`). That fails the job visibly and stores no second entry. This is the intended result: a loud failure beats silent duplicate time.

When you add a field to the key, check whether normalization can fill it from the workspace. If it can, leave it out, or hash the raw file value from before the fallback.

## Why it matters

A key that drifts gives no warning. The rerun succeeds, the import reports complete, and the customer has two copies of the same billed hours. The currency fallback got into the key even after user, project and bill status had been deliberately left out. Fallbacks hidden inside normalization are the easy ones to miss.

## Evidence

- PR #208, `app/services/imports/harvest_time_entries_importer.rb`: the comment above `ROW_KEY_FIELDS` explains why workspace values, the currency fallback included, are left out of the key. `row_idempotency_key` builds the UUID from the data import id and the digest.
- PR #208, `app/services/timekeeping/entry_write_client.rb`: `create_entry` takes an `idempotency_key:` that replaces the key derived from the request id.
- PR #208, `spec/services/imports/harvest_time_entries_importer_spec.rb`: "keeps a forwarded row's Idempotency-Key when the company's base currency changes before a rerun" sends the first row twice under one key, and the fake stores two entries for two rows. "keeps a row's key when the project turns non-billable before a rerun, so Timekeeping refuses it instead of storing it twice" expects `Timekeeping::EntryWriteClient::Rejected` and one stored entry.
- In PR #208 review, the currency case was first found because currency was in the key. It was removed, and the spec above was added.
