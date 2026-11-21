---
module: spec/support/timekeeping
date: 2026-11-21
problem_type: convention
component: testing_framework
severity: medium
audience: both
related_components:
  - spec/meta
tags:
  - prism
  - rspec
  - static-analysis
  - traceability
applies_when:
  - Reading RSpec example names or tags from source with Prism instead of loading the file
  - Using statically read examples as proof that a test exists
---

# Check Prism parse success before reading spec examples statically

## Context

Some helpers under `spec/support/timekeeping` read spec files with Prism, a Ruby parser, instead of loading them into RSpec. `TimekeepingIntegrationTags.example_names` is one of them. It lists example names so that a traceability check can confirm that each failure case in a design document has a test.

Problem: `Prism.parse` does not fail on broken Ruby. It returns a result with errors **and** a recovered syntax tree. In that tree, an `it "A" do ... end` inside a `describe` that has no closing `end` is still present. A walker that reads `Prism.parse(source).value` therefore returns names from a file that RSpec cannot load, so none of those examples ever runs. The traceability check would pass on a broken file.

## Solution

Keep the parse result, and raise before walking unless it succeeded:

```ruby
result = Prism.parse(source)
unless result.success?
  error = result.errors.first
  raise ArgumentError, "the spec source does not parse: line #{error.location.start_line}: #{error.message}"
end

example_names_in(result.value, false).freeze
```

Put the check in the reader whose output counts as proof. In this change, the existing `violations` check was left as it was.

## Why it matters

A reader whose output proves coverage must never report more than RSpec would run. With a recovered tree, the reader reports examples from a file that runs nothing. A full rspec run would show the load error, but only if the full suite runs. A focused traceability spec would still pass. Raising at the parse step fixes this where it starts, and the error gives the line of the broken code.

## Evidence

- PR #519 adds the `result.success?` check to `example_names` in `spec/support/timekeeping/integration_tags.rb`. The comment there says Prism still returns a recovered tree but RSpec cannot load the file.
- `spec/meta/timekeeping_integration_tags_spec.rb` adds the example "raises naming the parse error line when the source is not valid Ruby". It feeds a `describe` with no closing `end`, expects `ArgumentError` matching `/does not parse: line \d+/`, and checks that a valid control source still returns `["Relay down"]`.
- A review of PR #519 found that the first version threw the parse errors away. The author's check on the fixed code returned: `the spec source does not parse: line 3: unexpected end-of-input, assuming it is closing the parent top level context`.
