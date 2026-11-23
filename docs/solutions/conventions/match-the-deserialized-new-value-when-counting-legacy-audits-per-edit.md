---
module: timekeeping
date: 2026-11-23
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - audited
  - timesheet-entries
tags:
  - audits
  - audited-changes
  - exactly-once
applies_when:
  - A spec counts legacy audits rows for one TimesheetEntry edit
---

# Match the deserialized new value when counting legacy audits per edit

## Context

Legacy `TimesheetEntry` changes are audited in the `audits` table. Its `audited_changes` column is serialized text. For an update, each changed field holds a pair: `[old, new]`.

Say a spec counts audit rows for one edit with `audited_changes LIKE '%note%'`. That match also finds the next edit's row, because the next edit stores this note as its old value. An exactly-once check then sees two rows for every edit except the last one.

## Solution

Load the rows, deserialize them, and count only the rows where the note's new value matches:

```ruby
Audited::Audit.where(auditable_type: "TimesheetEntry", auditable_id: edit[:entry_id],
                     associated_type: "Company", associated_id: edit[:company_id]).to_a.count do |audit|
  note = audit.audited_changes["note"]
  note.is_a?(Array) && note.last == edit[:note]
end
```

The `is_a?(Array)` check skips the create row, which stores a single value and not a pair. Give every edit a new note and a new duration. Only changed fields reach the audit, so a repeated value would leave no note to match.

The prepared monolith's `entry_audits` and Timekeeping's `audit_events` do not need this. Match them with `after->>'note' = $3`.

## Why it matters

A text match passes when a spec has only one edit. It fails, or counts wrong, as soon as edits chain. A reviewer can miss this because the SQL looks correct.

## Evidence

PR #572 adds `legacy_alternating_audit_count` in `spec/integration/timekeeping/alternating_writers_spec.rb`. Its comment explains the `[old, new]` problem. The same file's `next_alternating_edit` changes both note and duration on every edit, and its comment says a converted audit holds only the fields that changed.
