# frozen_string_literal: true

require "json"
require "tmpdir"

module TimekeepingDemo
  # The `bin/timekeeping-demo regression` run: the section 12.1 regression
  # specs of docs/architecture/timekeeping-soa.md, once in each Timekeeping
  # ownership state, then once more for the examples tagged :switches_owner,
  # whose own subject switches owners and so cannot run inside one state.
  #
  # The bin script loads no Rails, so this file uses only the standard library
  # and writes out the environment keys the spec harness reads; a spec pins
  # them to TimekeepingOwnerState and TimekeepingQueueLedger.
  module Regression
    EX_OK = 0
    EX_FAILURE = 1

    STATES = %w[legacy timekeeping rollback].freeze

    SPECS = %w[
      spec/models/timesheet_entry_spec.rb
      spec/policies/timesheet_entry_policy_spec.rb
      spec/requests/api/v1/timesheet_entries/bulk_actions/update_spec.rb
      spec/requests/api/v1/timesheet_entries/bulk_actions/destroy_spec.rb
      spec/requests/api/v1/timesheet_entry/index_spec.rb
      spec/requests/api/v1/cli/timesheet_entries/create_spec.rb
      spec/requests/api/v1/cli/timesheet_entries/update_spec.rb
      spec/requests/api/v1/cli/timesheet_entries/destroy_spec.rb
      spec/mcp/tools/write_tools_spec.rb
      spec/mcp/idempotency_store_spec.rb
      spec/requests/api/v1/agent/timesheet_entries/create_spec.rb
      spec/requests/api/v1/invoices/create_spec.rb
      spec/models/invoice_spec.rb
      spec/models/invoice_line_item_spec.rb
      spec/requests/api/v1/invoices/send_invoice_spec.rb
      spec/system/invoices/send_invoice_spec.rb
      spec/services/imports/harvest_time_entries_importer_spec.rb
      spec/services/reports/time_entries/
      spec/services/analytics/team_productivity_analytics_spec.rb
      spec/services/metrics/data_builder_spec.rb
      spec/characterization/invoice_entry_locking_spec.rb
      spec/characterization/timesheet_entry_rules_spec.rb
      spec/characterization/entry_lookups_and_pdf_totals_spec.rb
    ].freeze

    OWNER_STATE_KEY = "TIMEKEEPING_OWNER_STATE"
    # The switches_owner pass sends the key set to "" rather than removing it:
    # dotenv fills only absent keys, so a removed key would come back from a
    # local .env file. config/application.rb deletes an empty value right
    # after dotenv loads, so the child's harness sees no state.
    NO_OWNER_STATE = ""
    LEDGER_PATH_KEY = "TIMEKEEPING_QUEUE_LEDGER_PATH"
    LEDGER_FILE = "queue_ledger.json"
    REPORT_FILE = "switches_owner.json"
    CHILD_ENV = { "TIMEKEEPING_REGRESSION" => "1", "TIMEKEEPING_LIVE" => "1" }.freeze
    SWITCHES_OWNER_TAG = "switches_owner"
    # A state run whose filters leave nothing to run must fail rather than pass
    # while proving nothing. rspec-core 3.13 has no --fail-if-no-examples
    # command-line option, so spec/spec_helper.rb sets
    # config.fail_if_no_examples for a regression child that has a state.
    # spec/lib/timekeeping_demo/regression_spec.rb pins that rspec rejects the
    # option, so an upgrade that adds it fails that spec.
    STATE_FLAGS = ["--tag", "~#{SWITCHES_OWNER_TAG}"].freeze
    REPORT_HEADING = "#{SWITCHES_OWNER_TAG} examples (run once, outside the ownership states):".freeze

    module_function

    # Runs every state in order, even after one fails, then the
    # switches_owner pass, and answers EX_OK only when all of them passed.
    # The runner is called as runner.call(env:, argv:) and passes a run only
    # by returning true.
    def run(runner:, states: STATES, specs: SPECS)
      unknown = states - STATES
      raise ArgumentError, "unknown ownership state #{unknown.join(', ')}; use #{STATES.join(', ')}" if unknown.any?

      states_passed = states.map { |state| run_state(runner, state, specs) }
      report_passed = run_switches_owner_report(runner, specs)
      states_passed.all? && report_passed ? EX_OK : EX_FAILURE
    end

    def run_state(runner, state, specs)
      passed = Dir.mktmpdir("timekeeping-regression-#{state}") do |dir|
        runner.call(env: child_env(dir, state), argv: [*specs, *STATE_FLAGS]).equal?(true)
      end
      puts "#{state}: #{passed ? 'passed' : 'failed'}"
      passed
    end

    # A json report the switches_owner pass wrote, holding the ids of the
    # examples it ran.
    Report = Data.define(:ids)
    # A report that is missing, not JSON, not shaped as rspec's json
    # formatter writes it, or not readable from disk; reason says which.
    UnreadableReport = Data.define(:reason)

    # This pass sets no owner state, so it does not fail when it finds no
    # examples: a readable report with no tagged example is a normal outcome,
    # reported as "none". The pass passes only when its runner returned true
    # and its report could be read, because without the report nothing shows
    # which tagged examples ran. The report is read before the temporary
    # directory holding it is removed, and lists whatever the file holds even
    # when the pass failed, so failing examples are still named.
    def run_switches_owner_report(runner, specs)
      Dir.mktmpdir("timekeeping-regression-switches-owner") do |dir|
        out = File.join(dir, REPORT_FILE)
        # The json formatter replaces the default one, so progress is named
        # again to keep rspec's failure details on stdout.
        argv = [*specs, "--tag", SWITCHES_OWNER_TAG, "--format", "json", "--out", out, "--format", "progress"]
        runner_passed = runner.call(env: child_env(dir, NO_OWNER_STATE), argv:).equal?(true)
        report = read_report(out)
        puts REPORT_HEADING
        case report
        in Report(ids: [])
          puts "none"
        in Report(ids:)
          puts ids
        in UnreadableReport(reason:)
          puts "unreadable report: #{reason}"
        end
        runner_passed && report.is_a?(Report)
      end
    end

    # The owner state always overrides the caller's value. Each child gets a
    # ledger of its own because a child rspec deletes the ledger it is given at
    # suite start.
    def child_env(dir, owner_state)
      { OWNER_STATE_KEY => owner_state, LEDGER_PATH_KEY => File.join(dir, LEDGER_FILE) }.merge(CHILD_ENV)
    end

    # Answers a Report or an UnreadableReport and never raises for a bad
    # file, so a pass that wrote no report, or a broken one, fails the
    # command with a reason instead of crashing it or passing as "none".
    def read_report(path)
      return UnreadableReport.new(reason: "no report at #{path}") unless File.exist?(path)

      case JSON.parse(File.read(path), symbolize_names: true)
      in { examples: Array => examples }
        Report.new(ids: examples.filter_map { |example| example[:id] if example.is_a?(Hash) })
      else
        UnreadableReport.new(reason: "#{path} has no examples list")
      end
    rescue JSON::ParserError => e
      UnreadableReport.new(reason: "#{path} is not valid JSON: #{e.message}")
    rescue SystemCallError => e
      UnreadableReport.new(reason: e.message)
    end
  end
end
