---
module: timekeeping
date: 2026-10-26
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: anchored
grounding_evidence: "spec/support/timekeeping/live_instance.rb in PR #121 runs every service command inside Bundler.with_unbundled_env with BUNDLE_GEMFILE set to the absolute timekeeping/Gemfile and chdir: SERVICE_DIRECTORY, and its comment says boot.rb keeps an inherited BUNDLE_GEMFILE."
audience: both
related_components:
  - timekeeping
  - spec_support
tags:
  - bundler
  - integration-test
  - subprocess
  - multi-app
applies_when:
  - A monolith spec spawns the timekeeping/ application as a real server
  - Running rails commands for one bundle from a process running under another
---

# Boot the Timekeeping sub-app from monolith specs with an unbundled environment

## Context

The live alert spec runs under the monolith's `bundle exec rspec` and starts a real Timekeeping server from `timekeeping/`. A child process inherits the parent's Bundler variables, including `BUNDLE_GEMFILE`.

The review of PR #121 found that `timekeeping/config/boot.rb` sets `BUNDLE_GEMFILE` with `||=`. It keeps whatever the parent passed. The child then loads the monolith's bundle. The root Gemfile does not declare the service's path gems (`timekeeping_rules`, `timekeeping_relay`), so the server cannot boot. Installing both bundles in CI does not change which one the child selects.

## Solution

Run every service command (`db:prepare`, `runner`, `server`) like this:

```ruby
Bundler.with_unbundled_env do
  Open3.capture2e(service_env, *command, chdir: SERVICE_DIRECTORY)
end
```

where `service_env` sets `"BUNDLE_GEMFILE" => File.join(SERVICE_DIRECTORY, "Gemfile")` as an absolute path, sets `RAILS_ENV`, and clears `DATABASE_URL` so the monolith's database setting cannot leak in. Give the server its own pid file and a free port. Make every boot failure raise, so a spec that asked for a live instance fails rather than passing without one.

## Why it matters

The failure looks like a missing gem or a broken service, not an environment leak, so it is easy to chase the wrong cause. The same rule holds for any command one bundle runs inside another bundle's directory in this repository.

## Evidence

- PR #121 adds `spec/support/timekeeping/live_instance.rb`. `run_in_service!` and `spawn_in_service` both wrap the command in `Bundler.with_unbundled_env`. The comment above them says boot.rb keeps an inherited `BUNDLE_GEMFILE`, so without a clean environment the service would load the monolith's gems and miss its own path gems.
- The same file's `service_env` sets the absolute `BUNDLE_GEMFILE` and `"DATABASE_URL" => nil`.
- PR #121's `timekeeping-alerts-live` job in `.github/workflows/validations.yml` installs both bundles and runs `spec/integration/timekeeping/alerts_live_spec.rb`.
