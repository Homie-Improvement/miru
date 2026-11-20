---
module: timekeeping_handoff
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: low
audience: author
related_components:
  - initializers
  - live_specs
tags:
  - rspec
  - initializer
  - to-prepare
  - env
  - factorybot
applies_when:
  - A spec sets ENV after boot and needs objects an initializer built from ENV to be rebuilt
  - The initializer builds its objects inside Rails.application.config.to_prepare
---

# Rerun one initializer in a spec by stubbing to_prepare and loading it

## Context

`config/initializers/timekeeping_handoff.rb` builds `TimekeepingStore` and the other handoff integrations inside a `to_prepare` block. Those objects capture their base URL and token from ENV when they are built. The live handoff spec learns its server's URL and token only after boot. So it must rebuild the configured integrations after it sets ENV, and again after ENV is restored.

The obvious way to run `to_prepare` again is the application reloader. That reruns every `to_prepare` hook in the app, including FactoryBot's reload. In this suite, that reload fails on the seed's top-level helper methods.

## Solution

Run only the one initializer. Make `to_prepare` yield its block at once, then load the file:

```ruby
def handoff_live_rebuild_integrations
  allow(Rails.application.config).to receive(:to_prepare).and_yield
  load Rails.root.join("config/initializers/timekeeping_handoff.rb").to_s
end
```

Call it inside the ENV override. Call it again in an `ensure` after the override ends, so later examples get integrations built from the real ENV.

## Why it matters

Without the rebuild, the runner keeps using integrations that point at the boot-time ENV. A live run then talks to the wrong server, or to none. With the full reloader, the spec fails for an unrelated reason. Stubbing and loading reruns exactly the code under test.

## Evidence

- PR #428 adds `handoff_live_rebuild_integrations` in `spec/integration/timekeeping/handoff_live_spec.rb`. Its comment says it reruns only this initializer because rerunning every `to_prepare` hook reloads FactoryBot, which fails on the seed's top-level helper methods.
- The same spec calls the helper inside `with_timekeeping_env` and again in the example's `ensure`.
- `config/initializers/timekeeping_handoff.rb` wraps all its assignments in `Rails.application.config.to_prepare`.
