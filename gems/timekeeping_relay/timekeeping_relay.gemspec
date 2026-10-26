# frozen_string_literal: true

require_relative "lib/timekeeping_relay/version"

Gem::Specification.new do |spec|
  spec.name = "timekeeping_relay"
  spec.version = TimekeepingRelay::VERSION
  spec.summary = "Delivers an entry snapshot outbox to the projection endpoint, in order and at least once"
  spec.description = "Reads unsent rows through an outbox source each application implements over its own " \
                     "database, posts them in outbox_position order, and marks them sent only after a 200. " \
                     "No Rails and no database of its own."
  spec.authors = ["Miru"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"
  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
end
