# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "timekeeping_handoff"
  spec.version = "0.1.0"
  spec.summary = "The time-entry handoff checkpoint and the store that exports and loads it"
  spec.description = "The checkpoint row shape, transport form and checksum, and the SQL store over a " \
                     "database's checkpoint tables, shared by the monolith and the Timekeeping service. " \
                     "It expects the host application to have loaded Active Record and Active Support."
  spec.authors = ["Miru"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"
  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
end
