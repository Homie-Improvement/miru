---
module: timekeeping_demo
date: 2026-11-18
problem_type: convention
component: development_workflow
severity: high
audience: both
related_components:
  - config/application.rb
  - config/puma_timekeeping_demo.rb
  - lib/timekeeping_demo/runtime_plan.rb
tags:
  - dotenv
  - environment-isolation
  - libpq
  - process-spawn
  - solid-queue
applies_when:
  - A launcher spawns the monolith with a hand-built environment and relies on keys being absent
  - A check in the launcher decides something (database user, which workers run) from the environment it passes
---

# Set keys a child must not pick up from dotenv, instead of dropping them

## Context

`bin/timekeeping-demo` starts the monolith and the Timekeeping app with `Process.spawn(..., unsetenv_others: true)`. That option removes every inherited variable, so the launcher seems to control the whole environment. It does not. The monolith loads `dotenv-rails` at boot, and dotenv reads the developer's local `.env` inside the child, after the launcher has checked its inputs. dotenv fills only keys that are absent.

Three paths opened this way during review:

- A `.env` with `DATABASE_URL`, `DB_USER` or `DB_PASS` could give the monolith a credential the launcher never checked against Timekeeping's.
- A `.env` with `PGUSER`, `PGPASSWORD`, `PGHOST` or `PGSERVICE` could change the user libpq (the Postgres client library) connects as when `config/database.yml` leaves it blank.
- A `.env` with `SOLID_QUEUE_IN_PUMA` makes `config/puma.rb` start the full Solid Queue supervisor, default worker included, inside the web server.

## Solution

Close each path where it starts, not with a broader filter:

1. Set every key the child must not take from `.env`, either to the caller's value or to `""`. A set key, even an empty one, stops dotenv from filling it. In `RuntimePlan::APPLICATIONS` this is the `always_set` list (`DATABASE_URL`, `DB_USER`, `DB_PASS`) and the `blanked` list (`TIMEKEEPING_DATABASE_URL`, `PGUSER`, `PGPASSWORD`, `PGHOST`).
2. Make the app read `""` as unset where an empty value would break boot. `config/application.rb` now runs `ENV.delete("DATABASE_URL") if ENV["DATABASE_URL"] == ""` right after dotenv loads, because Active Record refuses an empty URL.
3. Where a key cannot be blanked, remove what it points at. An empty `PGSERVICE` makes libpq fail with `definition of service "" not found`. So the launcher sets `PGSERVICEFILE` and `PGSYSCONFDIR` to `File::NULL` instead; a `PGSERVICE` from `.env` then fails to connect rather than picking an unchecked user.
4. Where a `.env` key switches behaviour on, load a config that has no such switch. The demo web process runs `puma -C config/puma_timekeeping_demo.rb`, which leaves out `plugin :solid_queue`.

## Why it matters

The launcher refuses to start when both apps would connect as one database user, and it starts only the dedicated queue workers. Both promises are checked on the environment the launcher builds. If the child can add keys after that check, the check proves nothing, and a seeded database's queued integration jobs can run. Unit specs on the environment hash stay green either way, so the gap is easy to ship.

The Timekeeping app loads no `.env`, so its processes get no blanked keys. Apply this rule per application, by whether that app loads dotenv.

## Evidence

- PR #354, `lib/timekeeping_demo/runtime_plan.rb`: the `APPLICATIONS` table holds `always_set`, `blanked` and `no_service_files` for the monolith, with a comment that dotenv-rails fills only absent keys.
- PR #354, `config/application.rb`: the new line that deletes an empty `DATABASE_URL`.
- PR #354, `config/puma_timekeeping_demo.rb`: the header says it leaves out the Solid Queue plugin because a `.env` can set `SOLID_QUEUE_IN_PUMA`.
- PR #354, `spec/lib/timekeeping_demo/runtime_plan_spec.rb`: examples assert the monolith database keys and `PGUSER`, `PGPASSWORD`, `PGHOST` are `""`, and `PGSERVICEFILE`, `PGSYSCONFDIR` are `File::NULL`.
- The author's recorded checks in PR #354: `PGSERVICE= psql ...` returned `definition of service "" not found`; with the service files set to `/dev/null`, a `PGSERVICE=demo_shared` returned `definition of service "demo_shared" not found`, while plain connections still worked.
- PR #354 had no spec that boots the monolith with a real `.env` and deferred that boot-level test. A later change added one for the regression report pass: `spec/meta/timekeeping_regression_spec.rb` boots child rspec processes in a temporary app tree with its own `.env.test.local`. That tree keeps the file away from other test processes using the checkout. The test checks that the file is read and that it does not restore `TIMEKEEPING_OWNER_STATE` in the switches_owner pass. The launcher's own keys (`DATABASE_URL`, `PGUSER` and the rest) are covered by `spec/lib/timekeeping_demo/boot_database_isolation_live_spec.rb`, which runs only with `TIMEKEEPING_LIVE=1`. It boots both apps through `bin/timekeeping-demo up` from a temporary tree. The tree's `.env.test.local` sets conflicting `DATABASE_URL`, `DB_USER`, `PGUSER`, `PGPASSWORD` and `PGHOST`. The spec checks that each app's live connections run as that app's own database user. A control removes the empty-`DATABASE_URL` deletion from the tree's copy of `config/application.rb` and expects the boot to fail.
