---
module: timekeeping_demo
date: 2026-11-18
problem_type: convention
component: development_workflow
severity: medium
audience: both
related_components:
  - lib/timekeeping_demo/runtime_plan.rb
tags:
  - database-url
  - libpq
  - credential-isolation
  - postgres
applies_when:
  - Code reads the database user out of a Postgres URL to compare or enforce it
---

# Refuse a database URL that names its user twice before comparing users

## Context

The demo launcher must refuse to start when the monolith and Timekeeping would connect as the same database user. It reads Timekeeping's user from `TIMEKEEPING_DATABASE_URL`. A Postgres URL can name the user in three ways: before the host (`postgres://role@host/db`), in a `user` query parameter, or in a `username` query parameter.

The first version read only `URI#user`. For `postgresql://timekeeping_role@127.0.0.1/timekeeping_demo?user=monolith_role` it returned `timekeeping_role`, but libpq connects as `monolith_role`. The check passed while both apps used the monolith's account.

## Solution

Collect every place the URL names a user: the decoded part before the host plus each `user` and `username` query value. Drop blanks, take the unique set, and raise `ConfigurationError` when more than one user remains. Only then compare the single user, falling back to the login user when none is named, as libpq does.

Do not try to copy one parser's precedence. libpq lets the query user win; Active Record keeps the user before the host. Either choice is wrong for one of the two code paths that open connections, so a URL with two users has no single correct answer.

## Why it matters

A user check that reads a different user than the connection does is worse than no check, because it reports isolation that is not there. Refusing an ambiguous URL costs the developer one edit and removes the guess.

## Evidence

- PR #354, `lib/timekeeping_demo/runtime_plan.rb`: `url_user` reads `uri.user` and the `URL_USER_PARAMETERS` (`user`, `username`) and raises `A database URL names more than one user: name it once`; its comment states the libpq and Active Record disagreement.
- PR #354, `spec/lib/timekeeping_demo/runtime_plan_spec.rb`: "refuses a database URL that names its user in more than one place" covers authority plus `user`, authority plus `username`, and two `user` parameters; another example refuses a shared user given only in the query.
- The author's recorded check in PR #354: before the fix, `url_user` returned `timekeeping_role` while libpq resolved `monolith_role` for the URL above.
