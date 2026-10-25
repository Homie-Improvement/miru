# Timekeeping contracts

These files are the single written form of the three Timekeeping contracts that `docs/architecture/timekeeping-soa.md` section 12.3 fixes before any lane builds against them:

- `entry_api.yml`: the user-delegated entry API (section 5.2).
- `reservations.yml`: prepare, commit and abort, the `mark-billed` and `detach-entries` service commands, and the save-reconciliation table for a replayed invoice save (sections 5.3, 7.2, 9.2 and 9.3).
- `entry_snapshots.yml`: the entry snapshot event the relay delivers to the projection endpoint (section 5.4).
- `idempotency.yml`: the idempotency rules shared by all three (section 5.1).

The files are data. `TimekeepingContract.load(name)` in `spec/support/timekeeping/contract.rb` reads one and returns it frozen. The RSpec shared examples in `spec/contracts/timekeeping/` and the fakes in `spec/support/timekeeping/` take field lists, reasons and rules from the loader, so a change here reaches every implementation that runs the examples.

The key lists in `entry_snapshots.yml` are exact. The entry fields are the columns of `timesheet_entries` in `db/schema.rb` plus `company_id` and `version`. A snapshot with any other key, such as a user name, an email or a token, breaks the contract. When a column is added to `timesheet_entries`, add it to `entry_fields` in the same change.
