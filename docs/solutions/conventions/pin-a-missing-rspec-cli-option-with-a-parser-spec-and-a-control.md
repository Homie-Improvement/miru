---
module: timekeeping_demo regression command
date: 2026-11-20
problem_type: convention
component: testing_framework
severity: low
audience: both
related_components:
  - lib/timekeeping_demo/regression.rb
  - spec/spec_helper.rb
tags:
  - rspec
  - fail-if-no-examples
  - option-parser
  - dependency-upgrade
  - regression-command
applies_when:
  - Code works around an option a locked dependency version does not have
  - A child rspec argv is built from a constant such as STATE_FLAGS
  - Someone asks to pass --fail-if-no-examples on the rspec command line
---

# Pin a missing rspec command-line option with a parser spec and a control

## Context

The `bin/timekeeping-demo regression` command runs child rspec processes, one per ownership state. A state run must fail when its filters leave no example, or it passes while proving nothing.

The obvious way is a `--fail-if-no-examples` flag in the child argv (`STATE_FLAGS` in `lib/timekeeping_demo/regression.rb`). The locked rspec-core 3.13.2 has no such command-line option. It has only the `config.fail_if_no_examples` setting. Running `RSpec::Core::Parser.parse(["--fail-if-no-examples"])` on that version prints `invalid option: --fail-if-no-examples` and exits 1. If the flag were added to `STATE_FLAGS`, every state child would abort before running an example, and the parent would see every state fail.

The setting and the missing flag share a name. That is why an earlier requirement asked for the flag in argv, and why a later reviewer can ask again. Before this change, only a code comment said the option did not exist. Nothing would notice if an rspec upgrade added it.

## Solution

Keep the guard in one place: `spec/spec_helper.rb` sets `config.fail_if_no_examples = true` when `TIMEKEEPING_REGRESSION` is `1` and `TIMEKEEPING_OWNER_STATE` is set. Then check the reason for that placement with a test, not a comment:

```ruby
it "has rspec's own option parser reject --fail-if-no-examples" do
  expect { RSpec::Core::Parser.parse(["--fail-if-no-examples"]) }
    .to raise_error(SystemExit)
    .and output(/invalid option: --fail-if-no-examples/).to_stderr
end

it "has rspec's own option parser accept the state flags" do
  expect { RSpec::Core::Parser.parse(described_class::STATE_FLAGS.dup) }.not_to raise_error
end
```

The second example is the control. It shows the parser call itself works on the real argv, so the first example fails only because of the option. The comments above `STATE_FLAGS` and above the guard name this spec, so a reader can find the proof.

When the first example starts failing after an upgrade, the option now exists. At that point the guard can move into `STATE_FLAGS` and the `spec/spec_helper.rb` branch can go. Do not keep both mechanisms.

## Why it matters

A claim like "this version has no option X" is true only for one version. A comment cannot tell you when it stops being true; a spec that calls the dependency's own parser can. The stderr matcher ties the first example's `SystemExit` to this option, so an unrelated error would not pass it. The control shows the same parser call accepts the real `STATE_FLAGS` argv, so the parser is reachable and the state argv parses cleanly.

This was seen for rspec-core 3.13.2 and its `--fail-if-no-examples` option only. Other rspec options and other versions need their own check.

## Evidence

- PR #436 adds the two examples in `spec/lib/timekeeping_demo/regression_spec.rb`, under the context "with the empty-run guard kept out of the state argv".
- PR #436 edits the comment above `STATE_FLAGS` in `lib/timekeeping_demo/regression.rb` and the comment above the guard in `spec/spec_helper.rb` so both name that spec.
- The diff of `spec/spec_helper.rb` shows the guard as `config.fail_if_no_examples = true` under the `TIMEKEEPING_REGRESSION` and `TIMEKEEPING_OWNER_STATE` check.
- The author ran `bundle exec ruby -e 'require "rspec/core"; RSpec::Core::Parser.parse(["--fail-if-no-examples"])'` on rspec-core 3.13.2. It printed `invalid option: --fail-if-no-examples` and exited 1.
- This change closes issue #430, which recorded the contradiction between the argv requirement and the `spec/spec_helper.rb` guard.
