---
module: spec/support/timekeeping
date: 2026-10-27
problem_type: convention
component: testing_framework
severity: low
evidence_grounding: anchored
grounding_evidence: "In PR #224, spec/contracts/timekeeping/forwarded_timekeeping_helpers_spec.rb spies on the fake's register_* methods and on route_timekeeping_to_fake and runs no import. The left-company example in spec/jobs/data_import_job_spec.rb has no register_user spy."
audience: both
related_components:
  - timekeeping
  - imports
  - jobs
tags:
  - spec-helpers
  - test-duplication
  - fake-timekeeping
  - env-restore
applies_when:
  - Extracting copied spec setup into a support helper
  - Writing a spec for a spec support helper
---

# Check a shared spec setup helper by its direct effects, in its own spec

## Context

PR #224 replaced eight copied forwarded-Timekeeping setups with `arrange_forwarded_timekeeping` and `with_forwarded_timekeeping_env` in `spec/support/timekeeping/forwarded_timekeeping_helpers.rb`. The first versions of the tests for the helper went wrong in two ways:

- The helper spec ran a full Harvest import through the fake. It checked the request paths, `user_id`, `project_id` and the import status. The `DataImportJob` example already checks all of these.
- A job example spied on the fake's `register_user` to count how the helper registered users. That example could then fail only because of a helper change, never because of the job.

Both put the same contract in two files. That is the drift the helper was added to remove.

## Solution

Give the helper one spec, and check only what the helper itself does:

- **State it sets:** the ownership row and the fake both end at owner `"timekeeping"`, generation 2. This holds even when an earlier step left generation 7.
- **Calls it makes:** spy with `and_call_original` on `register_company`, `register_user` and `register_project`, and on `route_timekeeping_to_fake`. Assert the arguments, and that it registers exactly the users it is given.
- **Environment it restores:** both variables are set inside the block and put back afterwards, including when the block raises `Timekeeping::Gateway::StaleGeneration`. If a variable leaked, later legacy examples would forward their writes without meaning to.

Leave what a forwarded import sends to the importer and job specs. Do not spy on the helper from the specs that use it. When a caller relies on a helper behavior, such as "registers only the users passed in", add a comment that points to the helper spec.

## Why it matters

If a feature contract is checked in both the helper spec and the feature spec, a change to that contract means editing both files. It is easy to update one and miss the other. A spy in a caller ties an unrelated example to how the helper works inside. Checking direct effects keeps each fact in one place. It also catches the one helper failure that matters most: a dropped registration or a leaked environment variable, which would break every group that uses the helper.

## Evidence

- PR #224, `spec/contracts/timekeeping/forwarded_timekeeping_helpers_spec.rb`: the first example spies on the fake's registration methods and on `route_timekeeping_to_fake`, and runs no import. The reset example checks that one user is registered. The environment examples check that both variables are restored, including after a raise.
- PR #224, `spec/jobs/data_import_job_spec.rb`: the left-company example has no `register_user` spy. Its comment says the helper spec checks that the helper registers exactly the users it is given.
- Two build reviews and one code review of the change flagged the import scenario in the helper spec and the spy in the job spec. The author removed both, and the helper spec then ran with 4 examples and 0 failures.
