---
module: config/environments
date: 2026-11-15
problem_type: convention
component: configuration
severity: low
audience: both
related_components:
  - host_authorization
  - action_mailer
tags:
  - env-vars
  - app-base-url
  - environment-files
  - blank-values
applies_when:
  - A file under config/environments reads an environment variable with a default
  - A shared helper in config/initializers already treats blank values as unset
---

# Treat blank environment values as unset in Rails environment files

## Context

`ENV.fetch("APP_BASE_URL", default_base_url)` returns the default only when the variable is missing. A deployment tool can set a variable to `""`, to spaces, or to a trailing newline. `fetch` keeps that blank value.

In `config/environments/production.rb` the blank value then reached two places. The mailer asset host became a blank string. `URI.parse(app_base_url).host` returned nil, so host authorization lost the host it parses from the base URL. The host check still passed only because `miru-production.onrender.com` is also listed as a literal, which hid the defect.

The repository already has a module, `AppBaseUrl` in `config/initializers/app_base_url.rb`, that treats a blank value as unset. The environment file cannot call it. Rails runs environment files before initializers, so the module is not defined yet.

## Solution

In environment files, read the variable with ActiveSupport's `presence`. It returns nil for empty and whitespace-only strings:

```ruby
default_base_url = "https://miru-production.onrender.com"
# Blank counts as unset, as in AppBaseUrl (config/initializers/app_base_url.rb), which
# this file cannot call because environment files run before initializers.
app_base_url = ENV["APP_BASE_URL"].presence || default_base_url
```

Keep the default literal in one local variable. Add a comment that names the initializer whose rule you copy, so a later change to one side points to the other.

## Why it matters

A blank variable is a normal mistake in a deployment dashboard. With `fetch`, it gives a running app with broken mail links and a host list that depends on a duplicate literal. That failure is silent. The copied rule is a small duplicate, but nothing better exists here: the shared module loads too late. The comment makes the duplicate easy to find.

## Evidence

- PR #308 changes `config/environments/production.rb` from `ENV.fetch("APP_BASE_URL", default_base_url)` to `ENV["APP_BASE_URL"].presence || default_base_url`, with a comment that names `config/initializers/app_base_url.rb` and says environment files run before initializers.
- The new spec `spec/config/environments/production_spec.rb` loads the file with APP_BASE_URL set to `""`, `"  "` and `"\t \n"`. It checks that `config.action_mailer.asset_host` equals `config.x.default_base_url` and that `config.hosts` includes its host. It also checks that `https://boot-check.test` is still used.
