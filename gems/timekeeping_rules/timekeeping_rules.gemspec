# frozen_string_literal: true

require_relative "lib/timekeeping_rules/version"

Gem::Specification.new do |spec|
  spec.name = "timekeeping_rules"
  spec.version = TimekeepingRules::VERSION
  spec.summary = "Timekeeping entry rules A1 to A11 as pure functions"
  spec.description = "Decides who may see, create for, change, delete and bulk-change timesheet entries. " \
                     "Plain values in, symbols out: no Rails and no database."
  spec.authors = ["Miru"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"
  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
end
