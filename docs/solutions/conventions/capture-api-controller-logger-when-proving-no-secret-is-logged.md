---
module: spec/requests/internal
date: 2026-10-25
problem_type: convention
component: testing_framework
severity: medium
evidence_grounding: speculative
audience: both
related_components:
  - app/controllers/internal/v1/base_controller.rb
tags:
  - logging
  - secrets
  - request-specs
  - actioncontroller-api
applies_when:
  - A request spec asserts that a token, key or other secret never appears in a log line
  - The endpoint under test inherits ActionController::API rather than ActionController::Base
---

# Capture the API controller logger when you prove no secret is logged

## Context

Some specs exist to prove that a credential never lands in a log. They swap the logger for one that writes to a `StringIO`, run the request, then check that the captured text does not contain the token.

This kind of spec has two quiet ways to pass without checking anything:

- The test environment in this repository logs at ERROR, while production logs requests at INFO. A capture logger left at the default threshold never sees an INFO line that leaks a token.
- Controllers built on `ActionController::API`, such as `Internal::V1::BaseController`, do not inherit `ActionController::Base`. Swapping `Rails.logger` and `ActionController::Base.logger` does not reliably change the logger these controllers write through. A token logged from the endpoint can skip the capture completely.

In both cases the spec says "no token found" because it captured nothing.

## Solution

In the capture helper:

1. Build the capture logger on a `StringIO` and set `logger.level = Logger::DEBUG`, so a leak at any level is seen.
2. Swap `Rails.logger`, `ActionController::Base.logger` and `ActionController::API.logger`, and put all three back in an `ensure` block.
3. Add a control example. It writes a random marker through `Rails.logger` and a second one through the endpoint's own controller logger (`Internal::V1::Companies::ReferencesController.logger.info(...)`). Then it asserts that the capture holds both markers.

The control example is the part that makes the negative assertion mean something. If a later Rails upgrade or refactor sends controller logs somewhere else, the control fails first. The "no token in the log" example cannot then pass without having seen anything.

## Why it matters

A leak spec that captures nothing is worse than having no spec. It tells reviewers the endpoint is safe, and nobody goes back to check. The fix costs one more logger swap and one short example.

## Evidence

- PR #30, head commit afc290becdff3d32e8eef35a303ffb4e6b5f39e0, file `spec/requests/internal/v1/companies/references_spec.rb`. The `capture_logs` helper sets `Logger::DEBUG` and swaps and restores `Rails.logger`, `ActionController::Base.logger` and `ActionController::API.logger`. A comment there says the test environment logs at ERROR and production logs requests at INFO.
- The same file holds the control example, "catches a token written at INFO, proving the capture sees request-level logs". It logs one marker through `Rails.logger` and one through `Internal::V1::Companies::ReferencesController.logger`, and expects to find both.
- `app/controllers/internal/v1/base_controller.rb` in the same commit inherits `ActionController::API`.
- The claim that swapping only the `Base` logger misses API controller lines rests on a check run during code review of this pull request. The author reports that the check showed the API controller logger bypassing the capture, and `ActionController::API.logger` was added to the swap after that. The diff shows the fix, not the failing run. To see it yourself, remove the `ActionController::API.logger` swap and rerun the control example.
