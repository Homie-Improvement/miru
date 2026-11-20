---
module: spec/support/timekeeping
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - TenantStateDigest
tags:
  - sha256
  - row-to-json
  - digest
  - framing
  - postgres
applies_when:
  - Hashing PostgreSQL rows from one or more tables into a single content digest
  - A group of tables shares one digest, or a table has no primary key
---

# Frame and order rows as database text when you digest table state

## Context

The tenant state digest combines several tables into one SHA-256 per group. For example, the `receipts` group hashes `idempotency_receipts` and `service_idempotency_receipts` together. Several simple ways to build that hash miss real changes:

- Counts miss updates.
- Rows decoded into Ruby values lose the difference between NULL and an empty string.
- Plain concatenation feeds the same bytes to the hash when a row moves to the next table in the group, or when one row `"ab"` becomes the two rows `"a"` and `"b"`.
- Rows with no fixed order can hash differently between two takes even when nothing was written.

## Solution

- Read each row as `row_to_json(t)::text` in SQL, and hash that text exactly as returned. The JSON text writes `null` and `""` differently.
- Order by primary key: `id`, or `outbox_position` for the outbox tables. For `reservations`, which has no primary key, use `ORDER BY t`. PostgreSQL then compares the whole row, column by column. That order still covers a column added later.
- Frame every item with a tag and its byte length before you hash it. The table name becomes `"T#{name.bytesize}:#{name}"`, and each row becomes `"R#{row.bytesize}:#{row}"`. Because table names are hashed too, an empty group still has a fixed, non-trivial digest, and groups with different table lists get different empty digests; groups with the same tables share one (the monolith and Timekeeping entries groups both pin 0f408c…, and both invoice_operations groups pin 5a9c45…).
- Pin the empty-group digests as hand-written literals in the spec. Do not recompute them through `group_digest`, or a change to the framing moves the expected value with it.

## Why it matters

A digest that collides on a real change is worse than no digest, because it reports "no change" with confidence. Each rule above closes one collision that a simple test would not catch.

## Evidence

- PR #451, `spec/support/timekeeping/tenant_state_digest.rb`: `row_query` selects `row_to_json(t)::text ... ORDER BY #{table.order}`. `BY_WHOLE_ROW = "t"` is used for `reservations`. `frame` builds `"#{tag}#{text.bytesize}:#{text}"` with the tags `TABLE_FRAME = "T"` and `ROW_FRAME = "R"`.
- PR #451, `spec/meta/timekeeping_tenant_state_digest_spec.rb`: "tells apart a row moved to the other table of the group and a row split in two" covers the framing. "keeps a NULL column distinct from an empty string in row_to_json text" covers NULL against an empty string. `pinned_empty_group_digests` holds the hand-written literals, and its comment explains why they are not recomputed.
