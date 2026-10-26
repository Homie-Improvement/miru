# frozen_string_literal: true

# Lets a spec prove what the suite's registered before and after hooks do,
# which no single example can see from inside itself.
module InnerExampleThroughSuiteHooks
  # Runs one inner example with the suite's registered hooks, in a group the
  # surrounding run does not report, and returns its execution result.
  def run_inner_example_through_suite_hooks(metadata, &body)
    inner_results = []
    listener = Object.new
    listener.define_singleton_method(:example_finished) { |notification| inner_results << notification.example.execution_result }
    reporter = RSpec::Core::Reporter.new(RSpec::Core::Configuration.new)
    reporter.register_listener(listener, :example_finished)
    group = RSpec::Core::ExampleGroup.subclass(RSpec::Core::ExampleGroup, "inner example", [metadata], []) do
      it("runs the inner body", &body)
    end

    outer_example = RSpec.current_example
    begin
      group.run(reporter)
    ensure
      RSpec.current_example = outer_example
      RSpec.current_scope = :example
    end

    expect(inner_results.size).to eq(1)
    inner_results.first
  end
end
