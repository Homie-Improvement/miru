---
module: Timekeeping gateway
date: 2026-10-26
problem_type: design_pattern
component: service_layer
severity: high
evidence_grounding: anchored
grounding_evidence: app/services/timekeeping/gateway.rb checked_create_attributes validates an unsaved draft and copies its bill_status; app/services/timekeeping/entry_write_client.rb EDIT_FIELDS, CREATE_SOURCE and edit_fields cast a numeric duration string; spec/support/timekeeping/fake_timekeeping.rb malformed_duration? refuses a non-number duration in token mode.
audience: both
related_components:
  - Timekeeping::EntryWriteClient
  - TimesheetEntry
  - TimekeepingContract::FakeTimekeeping
tags:
  - forwarding
  - model-callbacks
  - defaults
  - type-casting
  - fakes
applies_when:
  - A write that used to save through an ActiveRecord model is sent to another service instead
  - A fake stands in for that service in request specs
---

# Replay the model's write rules before forwarding to a remote owner

## Context

When Timekeeping owns entries, the gateway sends the web and mobile writes over HTTP instead of calling `save!`. The routes and JSON stay the same, so it is easy to treat this as a transport change. It is not. Everything the `TimesheetEntry` model did on save stops happening:

- `ensure_bill_status_is_set` chose `non_billable` for a non-billable project. The service defaults every entry to `unbilled`.
- `ensure_bill_status_is_not_billed` refused a create already marked billed. The service accepts it, and the policy then blocks the user from editing the entry.
- The duration column cast the form string `"30"` to a number. The service takes duration only as a JSON number, so a form post that worked yesterday gets refused.

The model also never let an edit change an entry's source or user. A body that reused create defaults on update would have erased an imported entry's origin.

## Solution

- Before a forwarded create, build an unsaved draft with the same attributes, user and project, and call `validate!`. Refused input fails with the same 422 as before, and nothing is sent. Copy the defaults the draft filled, such as `bill_status`, into the body.
- Build each operation's body on its own. Create carries `source: "manual"` and `source_metadata: {}` because the contract requires them. Update sends only the fields the controller permits (`EDIT_FIELDS`), with no source fields and no `user_id`.
- Cast form strings to the types the service requires, and leave invalid values unchanged so the service still refuses them.
- Make the fake enforce the provider's input shapes. A fake that stores any value lets form-posted specs pass while the real service refuses them.

## Why it matters

These failures are silent. The request succeeds, but non-billable work is recorded as billable, or an imported entry loses its origin. Only checks written against the model's old behaviour catch them.

## Evidence

In PR #170, `checked_create_attributes` in `app/services/timekeeping/gateway.rb` validates a draft and merges `"bill_status" => draft.bill_status`. `app/services/timekeeping/entry_write_client.rb` defines `EDIT_FIELDS`, `CREATE_SOURCE` and `edit_fields`, which sends a numeric duration string as a Float. `spec/services/timekeeping/gateway_spec.rb` covers the billed create refused with no request sent, and the forwarded bill_status of `non_billable` and `unbilled` for two projects. `spec/requests/api/v1/timesheet_entries/gateway_spec.rb` checks that a note-only edit keeps `source`, `source_metadata` and `user_id`. `spec/support/timekeeping/fake_timekeeping.rb` adds `malformed_duration?`, and `spec/contracts/timekeeping/fake_timekeeping_spec.rb` shows token mode refuses `"duration" => "30"` with 400.
