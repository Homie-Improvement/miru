---
module: api/v1/cli
date: 2026-11-21
problem_type: convention
component: api_layer
severity: medium
audience: both
related_components:
  - timekeeping_gateway
  - timesheet_entry
tags:
  - strong-parameters
  - source-metadata
  - timekeeping
  - ownership-states
applies_when:
  - A controller passes a nested permitted parameter (a Hash-valued field like `source_metadata`) into a service that may forward it to Timekeeping
  - A write behaves correctly in the legacy ownership state but not in rollback or timekeeping
---

# Convert permitted nested params to a plain Hash before they reach the Timekeeping gateway

## Context

Time entries can live in one of three stores, depending on the ownership state: the monolith (legacy), the Timekeeping app (timekeeping), or the prepared local store after a rollback. Controllers hand write attributes to a gateway, and the gateway picks the store.

The CLI timesheet entries controller passed `cli_timesheet_entry_params[:source_metadata]` straight through. That value is an `ActionController::Parameters` object, not a Hash. In legacy, `entry.update!` casts it through the json column, so the metadata is kept. In rollback and timekeeping, the gateway's update path keeps metadata only when it is a plain Hash. Any other value is normalized to empty metadata. The result: a CLI or MCP update that sent AI metadata lost it, and the entry was stored with source `"cli"` instead of the inferred `"automation"`. Legacy specs never showed this, because legacy hides the difference.

## Solution

At the controller, convert the permitted nested value once, in one method that both create and update use:

```ruby
def source_metadata
  cli_timesheet_entry_params[:source_metadata]&.to_h
end
```

Rules for this conversion:

- Use `ActionController::Parameters#to_h` on the already permitted value. Never use `to_unsafe_h` or `permit!`. The value still goes through the model's key allow-list, so keys such as `pii` stay dropped.
- Keep the safe navigation (`&.`). An omitted key must stay `nil`, and update must still set the attribute only when the request has the key (`if cli_timesheet_entry_params.key?(:source_metadata)`). Otherwise an update that leaves metadata out would wipe the stored value.
- Fix it at the controller, where Parameters enter the service layer. Do not make the gateway accept Parameters. The gateway's callers should pass plain data.

To prove a fix like this, arrange the entry in the owning store (`arrange_owned_entries(rows, state: TimekeepingOwnerState.current)`) and read it back with `owned_entry`. An entry saved with `TimesheetEntry.create!` exists only in legacy, so in the other states the update cannot find it, and the metadata defect never shows.

## Why it matters

The loss is silent. The request returns 200, legacy runs are green, and only the stored metadata and the inferred source differ. Any new Hash-valued parameter passed to the gateway as Parameters will repeat the same bug in the non-legacy states. Converting at the boundary keeps the strong-parameters filter in force and gives every store the same plain input.

## Evidence

- PR #535 changes `app/controllers/api/v1/cli/timesheet_entries_controller.rb`. It adds the `source_metadata` method shown above, used by both `create_attributes` and `update_attributes`. Its comment states that the gateway's update path normalizes metadata only when it is a plain Hash, and that a request without the key stays nil so update leaves stored metadata alone.
- The new spec `spec/requests/api/v1/cli/timesheet_entries/update_source_metadata_spec.rb` arranges entries in the owning store and checks three cases: allowed keys are kept and `pii` is dropped, with `source` read back as `"automation"`; a non-Hash `source_metadata` leaves the stored metadata unchanged; and an update to another user's entry returns 404 and changes nothing.
- The PR #535 description reports that before this change, a CLI or MCP update with AI metadata lost it in the rollback and timekeeping states and was stored with source "cli", while legacy kept it.
- `spec/support/timekeeping/owned_entries.rb` gains `source_metadata` in `ROW_KEYS` and `OPTIONAL_COLUMNS` in this change, so specs can arrange stored metadata in every store.
