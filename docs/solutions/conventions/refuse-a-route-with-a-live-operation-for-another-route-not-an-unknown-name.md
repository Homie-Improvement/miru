---
module: timekeeping
date: 2026-11-21
problem_type: convention
component: timekeeping
severity: medium
audience: both
related_components:
  - timekeeping_rules
  - authorization
tags:
  - service-token
  - background-operations
  - route-isolation
  - refusal-specs
applies_when:
  - Writing or editing a spec that proves a service actor is refused on a route
  - Replacing a retired operation name in a service-actor fixture
---

# Refuse a route with a live operation for another route, not an unknown name

## Context

A background service actor carries a list of operation names. The access check grants an operation only where `TimekeepingRules::EntryRules::BACKGROUND_OPERATIONS` also lists it, and each listed name maps to a route. A service that holds `reservations.commit` must still get 403 on `prepare`. Specs prove this by building an actor without the right name and expecting a refusal.

The actor can be refused for two different reasons:

- Its names are unknown, so they count for nothing anywhere.
- Its names are valid, but they map to a different route.

Only the second reason tests route isolation. An actor whose names are unknown is refused even if the route map grants every valid name to every route.

## Solution

When a refusal spec needs a "wrong" operation, use a live allowlisted name that maps to another route. Keep unknown or removed names in a separate actor that tests the name check.

When `entries.import` left the allowlist, its actors in `spec/services/timekeeping/local_owner_service_access_spec.rb` were split this way:

```ruby
mark_billed_only = Timekeeping::LocalOwner::Actor.service(name: "invoices", company_id: 3,
                                                          operations: ["invoices.mark_billed"])
unknown = Timekeeping::LocalOwner::Actor.service(name: "invoices", company_id: 3,
                                                 operations: ["reservations.*", "admin", "entries.import"])
```

Both must get `:forbidden` on `prepare`, `commit` and `abort`, but for different reasons. Do not use a `reservations.*` name that grants the route under test, because the expected refusal would then be wrong.

## Why it matters

Before this change, the `import_only` actor held `entries.import`. After the name left the allowlist, that actor still got 403, so the spec stayed green. But it no longer proved that a valid name for one route is refused on another. A broken route map would pass it.

## Evidence

- PR #533 removes `entries.import` from `BACKGROUND_OPERATIONS` in `gems/timekeeping_rules/lib/timekeeping_rules/entry_rules.rb`.
- In `spec/services/timekeeping/local_owner_service_access_spec.rb`, the `import_only` actor becomes `mark_billed_only` with `invoices.mark_billed`. The removed name moves into the `unknown` actor. The comment above that example says an actor's operations count only where `BACKGROUND_OPERATIONS` also holds them.
- In `spec/services/timekeeping/local_owner_reservations_spec.rb`, the `prepare` refusal actors swap `entries.import` for `invoices.mark_billed` (next to `reservations.commit`) and for `agents.detach_entries`. The 403 expectations stay the same.
