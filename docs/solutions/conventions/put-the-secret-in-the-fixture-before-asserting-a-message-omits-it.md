---
module: spec/meta
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/support/timekeeping
tags:
  - credential-leak
  - negative-assertion
  - fixtures
  - error-messages
applies_when:
  - A spec asserts that an error message does not echo a URL, user or password
  - A fixture is meant to carry dummy credentials for a leak check
---

# Put the secret in the fixture before asserting that a message leaves it out

## Context

`TestDatabaseGuard.require_test_database_url!` must name only the database in its error, never the URL. The first version of the spec for this rule used `not_to include("leak_user")` and `not_to include("s3cret_pw")`. Its fixture URLs held no user or password at all. Those assertions pass whatever the message says, so a later change that echoed the URL's user and password would have stayed green.

## Solution

Build the fixture from named parts, so the values the test looks for are really in its input. Then assert against each part and against the whole URL:

```ruby
user = "leak_user"
password = "s3cret_pw"
["@[bad/x", "@[bad-host/leak_guard_db"].each do |rest|
  url = "postgresql://" + user + ":" + password + rest

  expect { described_class.require_test_database_url!(url) }.to raise_error(TestDatabaseGuard::NotATestDatabase) { |error|
    expect(error.message).not_to include(user)
    expect(error.message).not_to include(password)
    expect(error.message).not_to include(url)
  }
end
```

When you review a "does not leak" spec, look at the fixture first. Each string a negative assertion names should appear in the input the code receives.

## Why it matters

A negative assertion has no failing case if its value is missing from the input. The spec then reads as protection that does not exist. Building the URL from parts also keeps the dummy user and password visible as separate literals in the committed file, which the spec's own comment gives as its reason.

## Evidence

- In PR #445, a review of `spec/meta/test_database_guard_spec.rb` found that the unparseable-URL fixtures held no user or password. The `not_to include` checks were therefore vacuous. The author ran `grep -c 'leak_user:s3cret_pw'` on the file before the fix, and it returned 0.
- The final `spec/meta/test_database_guard_spec.rb` in PR #445 builds the URL from `user = "leak_user"`, `password = "s3cret_pw"` and two malformed host suffixes. It asserts that the message omits the user, the password and the URL.
- After the fix, the author ran `bundle exec rspec spec/meta/test_database_guard_spec.rb`, which passed with 0 failures.
