---
module: dependency security
date: 2026-11-14
problem_type: convention
component: development_workflow
severity: high
audience: both
related_components:
  - timekeeping
  - ci
tags:
  - bundler-audit
  - gemfile-lock
  - security-advisories
  - timekeeping
  - ci
applies_when:
  - Bumping a gem past a published security advisory
  - Adding a new Rails app or bundle with its own Gemfile.lock to the repository
  - Reviewing a change to the Security audit job in .github/workflows/validations.yml
---

# Bump and audit every Gemfile.lock, not only the root one

## Context

This repository holds more than one Ruby bundle. The monolith uses the root `Gemfile.lock`. The timekeeping service in `timekeeping/` is a separate Rails app with its own `timekeeping/Gemfile.lock`.

An earlier change bumped the root lock past advisories in actionpack, actionview, activesupport, addressable, loofah, nokogiri, rack and rails-html-sanitizer. The timekeeping lock kept the old, vulnerable versions. Nothing reported this. The "Security audit" job ran only `bundler-audit check --update`, which checks only the root lock, so the job stayed green.

## Solution

Treat each lockfile as its own target, both when you fix it and when you audit it.

- When you bump a gem for an advisory, search for every `Gemfile.lock` in the repository. Bump each one that locks the gem. In `timekeeping/`, regenerate the lock with Bundler and target the versions the root lock already uses. The service follows the monolith's Rails line.
- Give each lock its own audit command in the "Run bundler-audit" step. `bundler-audit check timekeeping` takes a directory argument and reads `timekeeping/Gemfile.lock`. It runs after `bundler-audit check --update`, so it uses the advisory database the first command has just refreshed.
- Do not add `continue-on-error` or `|| true`. The step runs as one shell block, so a finding from any command must fail the job.
- When you add a new bundle with its own lock, add an audit line for it in the same change. No check reports a lock that the job does not audit.

PR #263 does not audit `gems/timekeeping_relay/Gemfile.lock` or `gems/timekeeping_rules/Gemfile.lock`. Its plan says those two locks hold only rspec gems. If either one gets runtime dependencies, add an audit line for it.

## Why it matters

A passing audit job proves only that the locks it reads are clean. If a lock is not in the job, its vulnerable gems can stay deployed with no signal. In this case, the service kept vulnerable Rails and rack versions after the root lock was fixed. Fixing only the version numbers leaves the same gap open for the next advisory. Adding the audit line closes it.

## Evidence

- PR #263 adds `bundler-audit check timekeeping` to the "Run bundler-audit" step in `.github/workflows/validations.yml`, right after `bundler-audit check --update`. Before this change, that step had only the root-level command.
- PR #263 changes `timekeeping/Gemfile.lock` from actionpack/actionview/activesupport 8.1.4, addressable 2.9.0, loofah 2.25.2, nokogiri 1.19.4 (all eight platform variants), rack 3.2.7 and rails-html-sanitizer 1.7.1. The new versions are 8.1.4.1, 2.9.2, 2.25.3, 1.19.7, 3.2.8 and 1.7.2, with new CHECKSUMS lines for each.
- Issue #262 records the gap: the root lock had already been bumped, and the Security audit job did not audit `timekeeping/Gemfile.lock`.
- Still to verify: the PR body says bundler-audit could not run in its test environment. The first CI run of the Security audit job on PR #263 is the first audit of the new timekeeping lock.
