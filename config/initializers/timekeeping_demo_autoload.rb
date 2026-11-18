# frozen_string_literal: true

# lib/timekeeping_demo/cli.rb defines TimekeepingDemo::CLI. A global "CLI"
# acronym, or an inflection keyed on the basename "cli", would also rename the
# existing Api::V1::Cli controllers, so only that one file path is mapped.
timekeeping_demo_cli_path = Rails.root.join("lib/timekeeping_demo/cli.rb").to_s
rails_inflector = Rails.autoloaders.main.inflector

Rails.autoloaders.main.inflector = Module.new do
  define_singleton_method(:camelize) do |basename, abspath|
    abspath == timekeeping_demo_cli_path ? "CLI" : rails_inflector.camelize(basename, abspath)
  end
end
