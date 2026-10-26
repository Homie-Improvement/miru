# frozen_string_literal: true

# Lets a spec chain several "did not change" checks with `.and`, which the
# block form `not_to change` cannot do.
RSpec::Matchers.define_negated_matcher :not_change, :change
