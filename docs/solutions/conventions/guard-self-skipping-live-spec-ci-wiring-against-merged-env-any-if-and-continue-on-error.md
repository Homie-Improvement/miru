---
module: ci
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - development_workflow
tags:
  - github-actions
  - meta-spec
  - live-spec
  - timekeeping
  - ci-guard
applies_when:
  - A spec skips itself unless an env flag such as TIMEKEEPING_LIVE is "1"
  - A meta spec in spec/meta checks that a workflow job runs that spec for real
---

# Guard a self-skipping live spec's CI wiring against merged env, any `if:`, and `continue-on-error`

## Context

`spec/integration/timekeeping/handoff_live_spec.rb` skips itself unless `TIMEKEEPING_LIVE` is `"1"`. So a CI job can name the spec and still go green with nothing tested. A meta spec exists to catch this. It reads `.github/workflows/validations.yml` and fails when no job runs the spec for real.

Early versions of the guard had three holes:
- It read only the job's `env`. GitHub Actions lets a step's `env` override the job's, so a step with `TIMEKEEPING_LIVE: "0"` turned the proof off and the guard stayed green.
- It flagged an `if:` only when the condition contained `head_commit.message`, `skip ci` or `github.event_name`. An `if: false` passed.
- The `skip ci` text check itself is risky. A push titled "Fix skip ci handling" would skip the proof.

## Solution

Check the values the rspec process will see, and treat any condition as a problem:

```ruby
# A step's env overrides the job's, and the rspec process sees the merged values.
env = (job["env"] || {}).merge(step["env"] || {})
{
  "does not set TIMEKEEPING_LIVE to \"1\"" => env["TIMEKEEPING_LIVE"] != "1",
  "does not name a _test database in TIMEKEEPING_DATABASE_URL" => !test_database_url?(env["TIMEKEEPING_DATABASE_URL"]),
  "ignores failures" => job["continue-on-error"] || step["continue-on-error"],
  "runs only under a condition" => job.key?("if") || step.key?("if")
}
```

Find the job by the run step that names the spec, not by job id. For each hole, write one example that changes the parsed workflow in memory and expects problems: step env override, job and step `if: false`, job and step `continue-on-error`, and the old skip-ci `if:`.

## Why it matters

A live proof that silently skips is worse than none, because the green check looks like coverage. Each of these settings is a one-line workflow edit that no reviewer would link to the proof. A block list of known condition texts only catches the cases someone already thought of. Rejecting the `if` key outright catches every case. The cost is that a deliberate condition later needs an explicit change to the guard.

## Evidence

- PR #477, `spec/meta/ci_spec_coverage_spec.rb`: `live_handoff_job_problems` merges job and step env, and checks `job.key?("if") || step.key?("if")` and `continue-on-error` on both. The examples "fails when the live handoff step overrides TIMEKEEPING_LIVE to \"0\"", "fails when the live job is disabled with if: false" and "fails when the live handoff step is disabled with if: false" cover the holes.
- PR #477, `.github/workflows/validations.yml`: the `timekeeping-alerts-live` job drops `if: github.event_name != 'push' || !contains(github.event.head_commit.message, 'skip ci')` and now runs `spec/integration/timekeeping/handoff_live_spec.rb`.
- In review, the step-env and `if: false` holes were confirmed against the earlier guard. The author's rspec run of `spec/meta/ci_spec_coverage_spec.rb` then reported 0 failures with the new examples.
