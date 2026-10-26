---
module: timekeeping
date: 2026-10-26
problem_type: design_pattern
component: service_layer
severity: high
evidence_grounding: speculative
audience: both
related_components:
  - authentication
  - timekeeping_rules
tags:
  - tenancy
  - authorization
  - reference-facts
  - entry-rules
  - actor-role
applies_when:
  - A service receives an actor (user id and role) from a caller and applies TimekeepingRules::EntryRules
  - The company id and the actor arrive as separate arguments
---

# Resolve the acting user's membership and role from the company's facts, not from the actor

## Context

`Timekeeping::LocalOwner.call` takes `company_id:` and `actor:` as separate keyword arguments. The actor carries a `user_id` and a `role`, as the gateway sends them. Nothing ties the two together. A user of company A can arrive paired with company B's id, and the role can be stale or belong to another company.

Filtering every row query by `company_id` does not close this gap. A create with no `user_id` in the body touches no existing row. The shared target-user rule then answers `:acting` ("write it for the acting user"), and the review of this change reported that this path does not check the acting user against the company's user list. The result would be a company B entry owned by a user who only belongs to company A. A caller-supplied `admin` role would also let an employee edit colleagues' entries.

## Solution

Before any rule runs, look the acting user up in `Timekeeping::ReferenceFacts` for the keyword company:

```ruby
facts = reference_facts
acting = facts && facts[:users].find { |user| user[:id] == actor.user_id }
return Outcome.refusal(:not_found) unless acting && project_known?(facts)

written = send(ROUTE_WRITERS.fetch(operation), facts, acting[:role])
```

- A user missing from the facts answers `not_found`, the same shape as another company's entry or project, and writes nothing.
- The role passed to `EntryDecision.target_user`, `EntryDecision.change`, `EntryDecision.bulk` and `EntryRules.visible_scope` is `acting[:role]` from the facts. `actor.role` is kept on the value object but never decides access.

Apply the same rule to any new writer that takes an actor and a company separately, including the reservation operations still to come.

## Why it matters

The shared rules decide on the values they are given. If the role and membership come from the caller, the rules faithfully enforce whatever the caller claims. Reading both from the company's own facts makes the company id the single source of truth for who may act there.

## Evidence

All from PR #148:

- `app/services/timekeeping/local_owner.rb`, `write_change`: the acting user is found in `facts[:users]`; a missing user answers `not_found`; `acting[:role]` is passed to the route writers.
- `app/services/timekeeping/local_owner/actor.rb`: the comment states access is decided on the role `Timekeeping::ReferenceFacts` reads for the company, so a stale or foreign role grants nothing.
- `spec/services/timekeeping/local_owner_spec.rb`: "uses the company's reference role, so an actor claiming admin cannot create a colleague's entry" expects 403, and "answers not_found when the acting user is not a member of the keyword company" expects 404 with no rows written.
- `spec/services/timekeeping/local_owner_tenancy_2_spec.rb`: "refuses a user actor who is not a member of the keyword company even when the body names no user_id".
- `spec/services/timekeeping/local_owner_tenancy_spec.rb`: "scopes a bulk_delete by the company's role for the user, not the role the actor claims".

The statement that the shared target-user rule answers `:acting` without a membership check comes from the review of this pull request; the rules file is not part of the diff. Verify it by reading `TARGET_USER_TABLE` in `gems/timekeeping_rules/lib/timekeeping_rules/entry_rules.rb`.
