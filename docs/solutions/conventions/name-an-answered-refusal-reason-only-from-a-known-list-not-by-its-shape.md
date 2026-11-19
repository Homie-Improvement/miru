---
module: Timekeeping handoff HTTP client
date: 2026-11-19
problem_type: convention
component: api_layer
severity: medium
audience: both
related_components:
  - Timekeeping::Handoff::TimekeepingStore
  - Timekeeping::Handoff::Store::Error
tags:
  - credential-redaction
  - error-messages
  - refusal-reasons
  - allowlist
applies_when:
  - A client puts text from a remote refusal answer into an exception message or a log
  - The remote call carries a bearer credential the answer could echo
---

# Name an answered refusal reason only from a known list, not by its shape

## Context

`Timekeeping::Handoff::TimekeepingStore` calls Timekeeping's internal handoff routes with the service bearer token. When a route answers with a status other than 200, `refuse_answer!` raises `Store::Error`. The message names the method, the path and the status. It can also add the `reason` field from the answer body, which helps an operator read the error.

The risk: a broken or hostile answer can echo the token back as its `reason`. Any text the client copies from the answer can then put the credential into exception messages and logs. Before this change, the client copied any `reason` that was a String.

An obvious fix is to copy only reasons that look like reason words, for example text that matches `/\A[a-z_]{1,64}\z/`. That is not safe. Nothing limits which characters the service token may contain. A token made only of lowercase letters matches that pattern, and the client would copy the whole credential into the message.

## Solution

Keep a fixed list of the reasons the routes are known to answer. Copy a reason only when it is exactly one of them. Any other answered text is dropped, and the message names only the method, path and status:

```ruby
REFUSAL_REASONS = %w[unauthorized forbidden invalid_request handoff_refused fence_timeout admission_missing].freeze

message = "Timekeeping #{method.upcase} #{path} answered #{response.code}"
message += " #{reason}" if REFUSAL_REASONS.include?(reason)
```

Test the case a shape check would miss. Send a token made only of lowercase letters as the reason, both bare and with a `Bearer ` prefix, and expect the exact message with no reason at the end.

The list must cover the error reasons in the handoff contracts. When a route starts to answer a new reason, add it here, or the error message will leave it out. That cost is safe: you lose some diagnostic detail, but the credential never leaks.

## Why it matters

A check on what a value looks like does not prove what the value is. A credential can always take the shape of a harmless word. Exact membership in a list the client owns is the only filter that cannot let a credential through. Echo tests that use only hex digits or a `Bearer ` prefix pass with the shape check too, so they give false confidence.

## Evidence

- PR #380 changes `lib/timekeeping/handoff/timekeeping_store.rb`. It replaces `message += " #{reason}" if reason.is_a?(String)` with `REFUSAL_REASONS.include?(reason)` and adds the `REFUSAL_REASONS` constant. A comment on that constant says that no other answered text is copied into `Store::Error`, whatever characters it holds.
- In the same pull request, `spec/lib/timekeeping/handoff/timekeeping_store_spec.rb` adds `names an answered refusal reason only when it is one the handoff routes answer`. It uses the token `service_token_only_lowercase_letters`, under the comment "A token made only of lowercase letters looks like a reason word". It expects exactly `Timekeeping POST /internal/v1/handoff/settle answered 409`.
- The same spec file sends the lowercase-only token `servicetokenonlylowercaseletters`, bare and Bearer-prefixed. It does this on settle, stop_applying and drain, with statuses 401, 409 and 503, and asserts that the message does not include the token.
- `contracts/timekeeping/handoff.yml`, added in this pull request, lists the reasons `unauthorized`, `invalid_request` and `admission_missing` under `errors`. All three are in `REFUSAL_REASONS`.
