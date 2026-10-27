---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: handoff
severity: medium
evidence_grounding: anchored
grounding_evidence: timekeeping/app/services/timekeeping/handoff/service_store.rb describe_invalid_entry prints 'id invalid' when entry[:fields] includes the field; service_store_spec.rb expects 'company_id 8 id invalid (id)' and no 'private-id-text'
audience: both
related_components:
  - service_store
  - checkpoint_entry_values
tags:
  - error-messages
  - privacy
  - checkpoint
applies_when:
  - An error message names the rows that failed a value check
  - The row identifiers are checked by the same rules as other fields
---

# Print an identifier as invalid when it failed its own rule

## Context

The checkpoint load refuses a checkpoint whose entries hold values the projection would refuse. The error is a `Checkpoint::ShapeError`, and its message can reach logs. The message names fields and identifiers, never field values, because values such as `note` can be private.

The first version printed `entry[:id]` for every bad row. But `id` is itself one of the checked fields. The checkpoint shape check only forces `company_id` to be an Integer, so a decoded `id` can be any text, such as `"private-id-text"`. Printing it copied private text into the error.

## Solution

Print an identifier's value only when it passed its own rule. When it failed, print the word `invalid` in its place:

```ruby
identifiers = { "company_id" => entry[:company_id], "id" => entry[:id] }
              .map { |field, value| entry[:fields].include?(field) ? "#{field} invalid" : "#{field} #{value}" }
```

The message for a text id then reads `company_id 8 id invalid (id)`.

## Why it matters

An identifier is safe to print only because a rule made it a number. Once the identifier is the thing under test, that guarantee is gone, and it is just another untrusted value. Scrubbing values but printing identifiers leaves this one hole open.

## Evidence

- PR #179 adds `describe_invalid_entry` to `timekeeping/app/services/timekeeping/handoff/service_store.rb`, with a comment that an invalid id or company_id can hold any text, including private text.
- `timekeeping/spec/services/timekeeping/handoff/service_store_spec.rb` adds an example that loads an entry with `"id" => "private-id-text"` and expects the message to include `company_id 8 id invalid (id)` and not include `private-id-text`.
- `timekeeping/spec/requests/internal/v1/handoff_checkpoint_spec.rb` checks that the 400 response body does not echo the note or the bad source value.
