# Timekeeping contracts

These files are the single written form of the three Timekeeping contracts that `docs/architecture/timekeeping-soa.md` section 12.3 fixes before any lane builds against them:

- `entry_api.yml`: the user-delegated entry API (section 5.2).
- `reservations.yml`: prepare, commit and abort, the `mark-billed` and `detach-entries` service commands, and the save-reconciliation table for a replayed invoice save (sections 5.3, 7.2, 9.2 and 9.3).
- `entry_snapshots.yml`: the entry snapshot event the relay delivers to the projection endpoint (section 5.4).
- `idempotency.yml`: the idempotency rules shared by all three (section 5.1).
- `reference.yml`: the company reference read the monolith serves to Timekeeping's background writes (section 3.4). `spec/requests/internal/v1/companies/references_spec.rb` checks the monolith's endpoint against it.

The files are data. `TimekeepingContract.load(name)` in `spec/support/timekeeping/contract.rb` reads one and returns it frozen. The RSpec shared examples in `spec/contracts/timekeeping/` and the fakes in `spec/support/timekeeping/` take field lists, reasons and rules from the loader, so a change here reaches every implementation that runs the examples.

## Running the examples against an implementation

The shared groups are `"timekeeping entry API contract"`, `"timekeeping reservations contract"`, `"timekeeping idempotency contract"`, `"timekeeping entry replay contract"`, `"timekeeping entry snapshot shape"`, `"timekeeping entry snapshot endpoint"` and `"timekeeping prepare reconciliation"`. Each runs on its own, so a provider can include only the groups for the routes it already serves. Require the group file from `spec/contracts/timekeeping/` and define:

- `timekeeping_client`: responds to `call(method, path, headers: {}, body: nil)` and returns a `TimekeepingContract::Response` with the status and the JSON body parsed into string-keyed Hashes.
- `timekeeping_arrange`: seeds companies, users, tokens, service identities, projects, entries and reserved entries, sets the ownership generation, and reads what the examples cannot reach through a route, such as a stored entry (`stored_entry`) and the number of outbox rows (`outbox_size`, which the replay group uses to show a replay wrote nothing). `TimekeepingContract::FakeArrange` lists every method.
- `reconciler`, for the reconciliation group only: responds to `call(remote_state:, intent_state:)`.

`spec/contracts/timekeeping/fake_timekeeping_spec.rb` and `fake_relay_spec.rb` run the groups against the in-memory fakes through the `"timekeeping contract fakes"` shared context. `mutation_spec.rb` breaks one rule of a fake at a time and checks that the matching group fails.

## What these contracts do not cover

The entry API contract covers the body's `user_id` (the target user), not which existing entries an employee may read or change. Whether an employee may see, edit or delete a colleague's entry in the same company (rows A1 and A4 of section 2.1, enforced in Timekeeping per section 6.3) is not checked here, and the fake Timekeeping lets any user of the company do it. A provider that passes these examples has not shown that rule. Its own specs must prove it.

## Exact keys

The key lists in `entry_snapshots.yml` are exact. The entry fields are the columns of `timesheet_entries` in `db/schema.rb` plus `company_id` and `version`. A snapshot with any other key, such as a user name, an email or a token, breaks the contract. When a column is added to `timesheet_entries`, add it to `entry_fields` in the same change.
