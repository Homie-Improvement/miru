---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: data_migration
severity: medium
evidence_grounding: anchored
grounding_evidence: lib/timekeeping/legacy_audit_conversion.rb json_values and its comment, called from row_for on audited_changes, and the spec 'writes Date and Time change values in the JSON form the jsonb columns hold' in spec/lib/timekeeping/legacy_audit_conversion_spec.rb
audience: both
related_components:
  - audited
  - checkpoint
tags:
  - jsonb
  - checksum
  - date
  - audited-changes
  - handoff
applies_when:
  - Building checkpoint rows whose values load into jsonb columns
  - Copying deserialized audited_changes or other Ruby hashes into a JSON column
---

# Convert values to their JSON form before checksumming rows bound for jsonb

## Context

The handoff checkpoint carries a checksum over its rows. The checksum tells a Date or Time apart from a string. A jsonb column cannot store a Date or Time: it stores the string. So a row built with a Ruby Date inside a jsonb value has a different checksum from the same row read back after the load.

This came up when legacy `TimesheetEntry` audits became `entry_audits` rows. The `audited` gem deserializes `audited_changes` into a hash that holds real `Date` values (such as `work_date`) and `Time` values (such as `discarded_at`). Those values went straight into `before` and `after`, which are jsonb. A real create-and-discard round trip showed that `work_date` came back as a string, so the checksums differed.

## Solution

Convert the value to the form the jsonb column will give back before it goes into the row:

```ruby
def json_values(changes)
  JSON.parse(changes.to_json)
end
```

`row_for` passes `audited_changes` through `json_values` before it splits them into `before` and `after`. A `Date.new(2026, 1, 2)` becomes `"2026-01-02"`, and a Time becomes its `as_json` string, which is what the loaded row holds.

Apply the same step to any value from Ruby objects that lands in a jsonb column of the checkpoint. Do it at the point the row is built, not in the checksum code, so the in-memory row and the stored row are the same data.

## Why it matters

The row passes the checkpoint shape check either way. The checksum mismatch appears only after export, load and re-read, which is late and far from the cause. Columns with their own SQL types (date, timestamp) keep their type, so the problem shows only for values nested inside JSON.

This was seen for Date and Time inside jsonb. The repository's other jsonb rule, which reads jsonb as text so decimals stay exact, is a separate issue and still applies.

## Evidence

- PR #90, head commit d2ca3d1191f4fa42215e4ab2cd416f757189d62a.
- `lib/timekeeping/legacy_audit_conversion.rb`: `json_values` and its comment, which says jsonb holds no Date or Time, such a value comes back as a string, and the checksum would no longer match. `row_for` calls it on `audited_changes`.
- `spec/lib/timekeeping/legacy_audit_conversion_spec.rb`: the example "writes Date and Time change values in the JSON form the jsonb columns hold" expects `"work_date" => "2026-01-02"` and `discarded_at.as_json`.
