---
module: timekeeping
date: 2026-11-15
problem_type: design_pattern
component: service_layer
severity: medium
audience: both
related_components:
  - authentication
tags:
  - service-actor
  - local-owner
  - prepared-store
  - audit
  - idempotency
applies_when:
  - A gateway branch calls Timekeeping::LocalOwner.call for a command that LocalOwner::ServiceAccess admits only from a service actor
  - A system-initiated write, such as a destroy callback, has no service credential in its write context
---

# Bind an app-built service actor to the record's company and one operation

## Context

The gateway's prepared-store writes call the local owner as a user actor for the signed-in user. The local owner is the code in the monolith that writes timekeeping entries while the prepared store owns them. Its `detach_entries` command admits only a service actor. The agent-destroy context carries no service actor, so the prepared branch of `Timekeeping::Gateway#detach_agent_entries` used to `raise OwnershipMoving`. That made every agent delete fail with a retryable 503. Every user or company delete that cascades into an agent failed the same way.

The fix builds a service actor in app code. This was the first service actor built in app code rather than taken from a signed token. A loose actor here grants more than the command needs.

## Solution

Build the actor inside the branch that needs it, fresh on each call:

```ruby
actor = LocalOwner::Actor.service(name: ServiceToken::SUBJECT, company_id: agent.company_id,
                                  operations: [ServiceToken::DETACH_ENTRIES])
```

Four rules apply:

- **Company comes from the locked record.** Use `agent.company_id`, never a request value. The credential can then touch only the agent's own company.
- **The operation list holds the one command.** `[ServiceToken::DETACH_ENTRIES]` grants nothing beyond what `ServiceAccess` checks for this call.
- **The name is the forwarded token's subject.** `ServiceToken::SUBJECT` is the name the gateway's comment says the forwarded detach's token carries. The local store records it as the audit row's actor name (`spec/models/agent_spec.rb`). This change does not show that the Timekeeping service records the same name on its audit rows; that is assumed.
- **The operation id is the forwarded path's id.** Pass `detach_operation_id(request_id:, agent_id:)`, the id the Timekeeping branch sends. A repeat of the same attempt then replays the stored answer. A retry with a new request id detaches entries created after the first attempt.

Read the answer through the shared `local_answer`. Refusals then raise the same errors a Timekeeping refusal raises, and the destroy rolls back. Keep every other prepared write on the user actor.

## Why it matters

There are two easy wrong turns here. Passing the user actor gets the call refused. Building a broad service actor, with a company from input or many operations, hands app code a credential that can write outside the record's company. If the operation id differs from the forwarded path, retries stop replaying the stored answer. A different name also stops the local audit rows from matching the service name the forwarded token is meant to carry.

## Evidence

- PR #332, `app/services/timekeeping/gateway.rb`: the `:prepared` branch now calls a new private `local_detach`. That helper builds the actor shown above. Its comment says the actor is bound to the agent's company and the detach operation alone, and is named like the forwarded token so both stores record the same service. It passes `self.class.detach_operation_id(request_id: context.request_id, agent_id: agent.id)` and reads the count through `local_answer(:detach_entries, outcome)`.
- `spec/services/timekeeping/gateway_spec.rb`: the call example asserts `actor.kind` is `:service`, `actor.user_id` is nil, `actor.company_id` is the agent's company, `actor.operations` equals `[Timekeeping::ServiceToken::DETACH_ENTRIES]`, and `actor.name` is `Timekeeping::ServiceToken::SUBJECT`. The real-local-owner example leaves another company's entry with the same agent id attached. The replay example adds no rows on a repeat with the same request id. The retry example clears a late entry under a new request id.
- `spec/models/agent_spec.rb`: a prepared `agent.destroy!` writes an audit row with actor type `service` and actor name `Timekeeping::ServiceToken::SUBJECT`. A 403 or a 409 `stale_generation` from the local owner rolls the destroy back.
- `docs/architecture/timekeeping-soa.md`: the gateway paragraph now calls the agent-entry detach the one prepared call not made as the signed-in user. It describes the company-bound service actor and the reused operation id.
