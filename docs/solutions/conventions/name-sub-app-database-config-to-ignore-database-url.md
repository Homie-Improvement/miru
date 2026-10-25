---
module: timekeeping
date: 2026-10-25
problem_type: convention
component: database
severity: medium
evidence_grounding: anchored
grounding_evidence: timekeeping/config/database.yml names its only config `timekeeping` with a comment on why; timekeeping/spec/boot_spec.rb example 'ignores a DATABASE_URL in the same environment' boots production with DATABASE_URL set and asserts the connection reaches the TIMEKEEPING_DATABASE_URL database
audience: both
related_components:
  - infrastructure
tags:
  - database-yml
  - database-url
  - multi-app
  - isolation
  - boot-spec
applies_when:
  - A separate Rails app in this repository must never use the monolith's database
  - A service reads its connection from its own environment variable, not DATABASE_URL
---

# Name a sub-app's database config so DATABASE_URL cannot replace it

## Context

The Timekeeping app at `timekeeping/` must share no database connection with the monolith. Its connection comes only from `TIMEKEEPING_DATABASE_URL`. If both processes run with the same environment, the monolith's `DATABASE_URL` is also set. Rails merges `DATABASE_URL` into the database config named `primary`. A sub-app with a default `primary` config could then connect to the monolith's database, and no error would show it.

## Solution

`timekeeping/config/database.yml` names its only config `timekeeping`, not `primary`, in every environment. It sets `url:` from `Timekeeping::Environment.database_url`, which calls `ENV.fetch("TIMEKEEPING_DATABASE_URL")` and raises when the variable is unset. The app has no fallback database.

Prove the isolation with a boot spec, not with a comment. `boot_spec.rb` starts `bin/rails runner` in production as a child process with `unsetenv_others: true`. The child gets only the four service keys, `RAILS_ENV` and the variables Ruby needs to find its gems. A second example adds `DATABASE_URL` pointing at an unreachable monolith host. Both examples assert that the config name is `timekeeping` and that `current_database()` is the Timekeeping database. The CI job also sets no `DATABASE_URL`.

## Why it matters

A wrong connection here does not fail loudly. The service would read and write the monolith's data, which breaks tenant and data ownership rules. Renaming the config costs nothing. The boot spec also catches any later setting the app reads from outside its four keys.

## Evidence

- PR #38, head commit a7ad4ffcfd080034c4dece77b8be9ab84c4c541a.
- `timekeeping/config/database.yml`: the config is named `timekeeping`. Its header comment says Rails reads `DATABASE_URL` for a config named `primary` only.
- `timekeeping/lib/timekeeping/environment.rb`: `database_url` uses `ENV.fetch(DATABASE_URL)` with no default.
- `timekeeping/spec/boot_spec.rb`: the examples "boots in production from the four Timekeeping keys alone" and "ignores a DATABASE_URL in the same environment".
- `.github/workflows/validations.yml`: the `timekeeping` job sets only `TIMEKEEPING_DATABASE_URL`. Its comment says a passing run shows that the service needs no monolith database setting.
