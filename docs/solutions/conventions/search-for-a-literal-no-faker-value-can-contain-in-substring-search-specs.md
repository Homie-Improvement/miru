---
module: team
date: 2026-11-15
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - api_layer
  - service_layer
tags:
  - rspec
  - faker
  - flaky-test
  - ransack
  - substring-search
  - team-index
applies_when:
  - A spec sends a substring search such as `q[first_name_or_last_name_or_email_cont]` and asserts an exact number of rows
  - The search term comes from a Faker-generated attribute
  - Other rows in the same setup carry Faker-generated names or emails
---

# Search for a literal that no Faker value can contain in substring-search specs

## Context

The request spec example "can search a user from the team" in `spec/requests/api/v1/team/index_spec.rb` searched with `first_name_or_last_name_or_email_cont: user.first_name` and expected exactly one row. In CI it failed with "Expected 2 to eq 1." in 3 of 3 runs on the base branch, while it could pass when run alone.

The cause was in the test data, not the search. The team index returns pending invitations as well as employees, and invitations match the search by their email. The group's shared invitation has a random Faker email, and a Faker email often builds its local part from a Faker name. When that email held the admin's random first name, the search returned the admin and the invitation.

The failure depended on Faker's random state across the full parallel suite, so a focused run does not reproduce it.

## Solution

Inside the one example, give the searched value a literal that no generated value can hold, then search for it:

```ruby
it "can search a user from the team" do
  # The pending invitation's random email can contain a random first name,
  # and invitations match the search by email, so search for a name no
  # generated email can hold.
  user.update!(first_name: "Zyxsearchable")
  send_request :get, api_v1_team_index_path(
    q: { first_name_or_last_name_or_email_cont: user.first_name }
  ), headers: auth_headers(user)
```

Rules that follow from this fix:

- Pin the value inside the example, not in the shared `let`. Other examples read the shared Faker values, and the factories stay Faker-backed, as `AGENTS.md` asks.
- Keep the exact-count assertion. The invitation row still exists and still does not match, so a search that ignored the query would return two rows and fail. Loosening the count to "includes the user" would hide that.
- Do not "fix" the search to stop matching invitations by email. That match is intended behaviour.

## Why it matters

A substring match is much wider than an equality match. Any Faker name, email or company in the setup can contain a short random first name, and the search may cover tables the spec does not mention. The result is a test that fails only under some seeds, often only in the full suite, and gets blamed on whatever change was in flight. A distinctive literal removes the chance of a collision instead of making it rare.

When you review a spec that searches with a `_cont` filter and asserts a count, check where the search term comes from. If it comes from Faker, ask for a literal.

## Evidence

- PR #296 adds `user.update!(first_name: "Zyxsearchable")` and a why-comment to the example "can search a user from the team" in `spec/requests/api/v1/team/index_spec.rb`. The comment states that invitations match the search by email and that the pending invitation's random email can contain a random first name.
- The PR body for PR #296 states the assertions are unchanged (still exactly one row, the admin) and that the original failure depended on Faker's random state across the parallel suite, so it was not reproduced alone.
- Issue #295, which PR #296 closes, records the failure "Expected 2 to eq 1." at `index_spec.rb:86`, red in 3 of 3 base-commit runs.
- The checks at the head of PR #296 show no failure.
