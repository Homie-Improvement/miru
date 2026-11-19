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
  - json-parsing
  - exception-causes
  - regression-testing
applies_when:
  - Testing malformed JSON replies that can echo service credentials
  - Replacing parser exceptions with application errors
---

# A Bearer-prefixed probe can miss a JSON parser credential leak

## Context

Test bare and JSON-embedded credentials, not only a `Bearer` prefix, when checking this client's malformed replies.

`TimekeepingStore` sends a service credential and reads JSON replies. A malformed reply can repeat that credential. The client replaces parser errors with `Store::Error`, but a safe replacement message alone does not remove the original exception.

The parser used here did not expose the credential for every malformed body. A probe returning `"Bearer #{token}"` omitted it from `full_message` even before the fix. A bare token and an invalid JSON field value exposed it.

## Solution

Exercise distinct reply forms when checking this boundary:

```ruby
token = "servicetokenechoedinbody"
answers = [
  "Bearer #{token}",
  token,
  %({"drained": #{token}})
]
```

Check the complete exception text with `error.full_message`, not only `error.message`. Also inspect `error.cause`, which holds the original exception when one error replaces another.

The proposed fix removes that original exception in the shared JSON reader:

```ruby
rescue JSON::ParserError => error
  raise Store::Error,
        "Timekeeping answered an unreadable body: #{error.class}",
        cause: nil
```

This keeps the parser error class for diagnosis without retaining its response-derived message. Both integer and boolean readers use the shared reader.

## Why it matters

The passing Bearer-prefixed probe established safety only for that body. It did not establish safety for other malformed replies.

A test that uses only the Authorization-header form can therefore miss a credential exposed through exception output. Keep the observed body variants when testing this client. Do not assume another parser or malformed body produces the same diagnostic text.

## Evidence

Pending PR #380 changes `lib/timekeeping/handoff/timekeeping_store.rb` to parse fields through `answer_field` and raise unreadable-body errors with `cause: nil`.

The recorded pre-fix probes exercised both `settle` and `drain`. For `"Bearer #{token}"`, `full_message` did not contain the token. For a bare lowercase token and `{"drained": <token>}`, `full_message` contained it. After the fix, both methods had no cause and no token in `full_message` for those bodies.

`spec/lib/timekeeping/handoff/timekeeping_store_spec.rb` adds the example `keeps a token echoed in an unreadable 200 answer out of the Store::Error cause and full message`. It tests the bare and JSON-embedded forms on both routes. The recorded focused store-spec result after the fix was 138 examples with 0 failures.
