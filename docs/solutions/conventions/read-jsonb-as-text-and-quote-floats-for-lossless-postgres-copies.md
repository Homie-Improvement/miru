---
module: timekeeping_handoff
date: 2026-10-26
problem_type: convention
component: data_migration
severity: high
evidence_grounding: anchored
grounding_evidence: gems/timekeeping_handoff/lib/timekeeping/handoff/table_store.rb read_rows and parse_jsonb, LosslessSql.json_text and LosslessSql.literal in gems/timekeeping_handoff/lib/timekeeping/handoff/lossless_sql.rb, Checkpoint::JSON_NULL in gems/timekeeping_handoff/lib/timekeeping/handoff/checkpoint.rb, and the jsonb decimal, JSON-null and -0.0 round-trip examples in spec/lib/timekeeping/handoff/monolith_store_spec.rb
audience: both
related_components:
  - active_record
  - postgresql
tags:
  - jsonb
  - bigdecimal
  - float-bits
  - lossless-copy
  - checksum
  - json-null
applies_when:
  - Copying rows between databases or applications and promising every value comes back unchanged
  - Computing a checksum over rows read through Active Record
  - Writing float8 or jsonb values back with hand-built SQL
---

# Read jsonb as text and write floats as quoted text when a copy must be lossless

## Context

The time-entry checkpoint promises that every value survives export and load unchanged. Active Record's normal read and write paths break that promise in three places, and none of them raises an error:

- **jsonb decimals.** The jsonb cast parses every JSON number as a Ruby Float. A number with more digits than a double holds, such as `1.00000000000000000001`, is rounded.
- **JSON null.** The same cast returns `nil` both for SQL NULL and for a jsonb cell that holds the JSON value `null`. The two become the same on the way back in.
- **Negative zero.** A bare `-0.0` in SQL is read as the negation of the number zero and stored as `0`.

A checksum does not catch any of these. It is computed from the values after they were read, so it already agrees with the rounded or merged value that load writes back.

## Solution

Fix the loss where the value is read and written, not after:

- Read jsonb columns from the raw result text and parse it with `JSON.parse(text, decimal_class: BigDecimal)`. Parse only those columns. Every other column keeps the normal `cast_values`.
- Give JSON `null` its own value, distinct from `nil`. The checkpoint uses a frozen `JSON_NULL` object. Encode it with its own tag and write it back as the literal `null`.
- Write jsonb back as JSON text that prints each BigDecimal as a bare number with `to_s("F")`. The default encoders print a BigDecimal as a quoted string.
- Write floats as quoted `Float#to_s` text cast to the column type, for example `'-0.0'::double precision`. `Float#to_s` gives the shortest decimal that reads back to the same bits.
- Inside JSON, encode a Float and a BigDecimal of the same decimal value the same way. Keep the bit-for-bit encoding for real float columns such as `duration`.

## Why it matters

A handoff that "verifies" while it changes audit values or metadata numbers is worse than one that fails. Operators trust the matching checksums and throw away the source. Test against the stored text (`column::text`, `before IS NULL`, `float8send(duration)`), not against decoded Ruby values. Decoded values hide all three losses.

This was seen on Postgres jsonb and float8 through Active Record 8.1. Other column types, such as `json` or `numeric`, were not checked in this change.

## Evidence

- PR #65, head commit 9ada49a6ef29197de28ad119fdef20747b20fa0b.
- `gems/timekeeping_handoff/lib/timekeeping/handoff/table_store.rb` (shared by the monolith's `MonolithStore` and Timekeeping's store): `read_rows` replaces jsonb cells with `parse_jsonb` of the raw text. The comment on `parse_jsonb` says the cast turns every decimal into a Float and reads JSON null as nil.
- `gems/timekeeping_handoff/lib/timekeeping/handoff/lossless_sql.rb`: `LosslessSql.json_text` writes BigDecimal with `to_s("F")`. The comment on `LosslessSql.literal` says an unquoted -0.0 is stored as 0, so floats go in as quoted text.
- `gems/timekeeping_handoff/lib/timekeeping/handoff/checkpoint.rb`: `JSON_NULL`, the `json_null` and `decimal` tags, and `encode_json_value`, which maps an in-JSON Float to the same decimal encoding as a BigDecimal.
- `spec/lib/timekeeping/handoff/monolith_store_spec.rb`: these examples check stored text after export, transport and load: "keeps JSONB decimals finer than a float exact", "keeps a JSON null apart from SQL NULL in a jsonb column" and "keeps jsonb decimals exact when the value is a root array or a bare number". The example "exports durations with the bits they are stored with" includes `-0.0` and `5e-324`.
