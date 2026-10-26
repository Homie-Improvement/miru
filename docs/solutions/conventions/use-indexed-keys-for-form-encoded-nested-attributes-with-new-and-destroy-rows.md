---
module: spec/requests
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: speculative
audience: both
related_components:
  - api_layer
tags:
  - nested-attributes
  - request-specs
  - form-encoding
  - invoice-taxes
  - refusal-tests
applies_when:
  - A request spec sends `*_attributes` for several nested rows as form parameters
  - The rows have different key sets, for example a new row with no id next to a row with only id and _destroy
---

# Use indexed keys for form-encoded nested attributes that mix new and destroy rows

## Context

The billing fence request specs send a PATCH that tries three nested tax writes in one request. It updates one tax row, adds a new row with no `id`, and deletes another row with `{ id:, _destroy: "1" }`. The specs send these parameters form-encoded, not as JSON.

In form encoding, an array of hashes is flattened to repeated `invoice[invoice_taxes_attributes][][field]` pairs. The server rebuilds the rows from those pairs. It starts a new row only when a key repeats. The new row carries `tax_configuration_id`, `name`, `calculation_method`, `value` and `amount`. The destroy row that follows carries only `id` and `_destroy`. No key repeats between them, so both arrive as one hash: a row that names `service_row`'s id, carries the "Added" fields and asks to be destroyed.

The request then no longer tries an add plus a separate destroy. A refusal test still passes, because the refused request writes nothing either way. So the test quietly checks less than its title and payload claim.

## Solution

Send each nested row under its own indexed hash key:

```ruby
invoice_taxes_attributes: {
  "0" => { id: gst_row.id, tax_configuration_id: gst.id, name: "GST", calculation_method: "percentage", value: 18, amount: 99 },
  "1" => { tax_configuration_id: service.id, name: "Added", calculation_method: "percentage", value: 3, amount: 3 },
  "2" => { id: service_row.id, _destroy: "1" }
}
```

The index becomes part of each parameter name, so every row stays separate whatever keys it has. Nested attributes accept this hash form the same way as an array.

The array form is safe only when every row repeats a key from the row before it. Both of these keep `id` in every row, so they split correctly:

- an array of rows that each hold `id` and `_destroy`
- an array of rows that each hold `id` and the update fields

If you are unsure, use indexed keys.

This change shows the problem only for form-encoded parameters. A JSON request body keeps array elements apart, and this change does not test that encoding.

## Why it matters

A refusal test proves something only if the request really tries the writes it lists. A merged row turns "update, add, destroy" into "update, and one odd row". The test stays green, and a later regression in the add path or the destroy path is no longer covered. Indexed keys make the payload the server sees match the payload the test author wrote.

## Evidence

- PR #113, head commit 22fcc0ddb15ab57f330e6f8c7f082bd7c7c35b71.
- `spec/requests/api/v1/billing_fence_2_spec.rb` and `spec/requests/api/v1/billing_fence_4_spec.rb` send the update, add and destroy tax rows as a hash with keys "0", "1" and "2". The comment above each payload says that indexed keys keep each row's fields together, and that a form-encoded array would merge the id-less new row and the destroy row into one hash.
- The PR body's record of earlier fixes says the retried-update example in `spec/requests/api/v1/billing_fence_2_spec.rb` was changed to send `invoice_taxes_attributes` with indexed keys, not as an array, "so the add and destroy rows arrive separately".
- In the same file, the destroy-all example (two `{ id:, _destroy: "1" }` rows) and the other-invoice example (two rows that each hold `id`) keep the array form. Every row in those arrays repeats the `id` key.
- The account of how the server rebuilds rows from repeated keys comes from general knowledge of form parameter parsing. This change does not show it, and nothing in the change tests the JSON-body case.
