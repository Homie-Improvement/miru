---
module: spec/requests
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - timekeeping
  - invoices
tags:
  - committed-data
  - let-it-be
  - rspec
  - live-timekeeping
  - ownership-states
applies_when:
  - Adapting a request-spec example to run against the live Timekeeping app
  - The example sits in a group whose setup uses `let_it_be`
---

# Move a committed_data example out of a let_it_be transaction group

## Context

In the timekeeping ownership state, the live Timekeeping app reads company and project rows on its own database connections. It can only see rows that are committed. The `committed_data: true` tag makes an example commit its rows.

That tag does not help inside a group whose `let_it_be` rows are created once for the whole group. Those rows sit in one open transaction that stays open while the group runs, and `committed_data: true` on a single example does not end it. The example's own writes, and the group's company, client and user, stay invisible to the live app.

## Solution

Do not tag the example in place. Move it into a second top-level `RSpec.describe` in the same file, and put the tag on that block:

```ruby
RSpec.describe "Api::V1::Invoices#create line items linked to an owned entry", type: :request,
  committed_data: true do
  let(:owned_entry_company) { create(:company, :with_logo, base_currency: "USD") }
  let(:owned_entry_client) { create(:client, company: owned_entry_company) }
  # ...
  before do
    create(:employment, company: owned_entry_company, user: owned_entry_admin)
    owned_entry_admin.add_role :admin, owned_entry_company
    sign_in owned_entry_admin
  end
end
```

- Rebuild what the original group gave the example (company, client, admin user, employment, role, sign-in) with plain `let` and `before`. This way each row is created and committed inside the example.
- Use prefixed `let` names, such as `owned_entry_company`, so the new block cannot be mixed up with the first group's names.
- Keep the example's title and every assertion. Leave the other examples' `let_it_be` setup alone.
- Add a comment above the block that says why it is separate. Otherwise a later cleanup may merge it back.

## Why it matters

If the example stays in the group, it passes in the legacy and rollback states, which do not need the live app. It fails only in the live timekeeping run, and the failure looks like missing reference data, not a transaction problem. Moving the example costs some repeated setup. Lifting the group's transaction would instead change setup for every other example in the file, so the move is the smaller change.

## Evidence

- PR #494 removes "creates invoice line items with date and timesheet entry associations" from the main group in `spec/requests/api/v1/invoices/create_spec.rb`. It adds the example back under a new top-level `RSpec.describe ... committed_data: true` block that builds company, client, admin, employment and role with `let` and `before`.
- The comment the change adds above that block states the reason: the live app reads company and project rows on its own connections, and the first group's `let_it_be` rows sit in one open transaction that `committed_data` does not lift.
- The PR body reports this example passing in the legacy, rollback and live timekeeping states.
