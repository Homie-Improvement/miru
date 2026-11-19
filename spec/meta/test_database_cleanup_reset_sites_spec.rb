# frozen_string_literal: true

require "rails_helper"

# Finds every place in the given sources that empties monolith tables, or
# collects queue executions, outside TestDatabaseCleanup.clean_with!. A reset
# that skips the collect step erases Solid Queue executions with no record,
# so each rule below lists how many matching lines a file may hold.
module TestDatabaseCleanupResetSiteScan
  WRAPPER_FILE = "spec/support/database_cleaner.rb"
  TIMEKEEPING_RESET_FILE = "spec/support/timekeeping/timekeeping_database_reset.rb"
  RUNTIME_QUEUES_FILE = "spec/timekeeping/runtime_queues_spec.rb"

  Rule = Data.define(:name, :pattern, :allowed, :only_in)

  RULES = [
    # The Timekeeping database reset collects through its before_truncate: hook.
    Rule.new(name: "direct collect", pattern: /\bTestDatabaseCleanup\.before_reset!/,
             allowed: { TIMEKEEPING_RESET_FILE => 1 }, only_in: nil),
    # The one call inside clean_with!.
    Rule.new(name: "direct DatabaseCleaner.clean_with", pattern: /\bDatabaseCleaner\.clean_with\b/,
             allowed: { WRAPPER_FILE => 1 }, only_in: nil),
    # Inside TestDatabaseCleanup the collect step is called without the module
    # prefix; only clean_with! may do that.
    Rule.new(name: "bare collect", pattern: /\A(?!\s*def\b).*(?<![.\w:])before_reset!(?!\w)/,
             allowed: { WRAPPER_FILE => 1 }, only_in: WRAPPER_FILE),
    # A SQL TRUNCATE statement: one that opens a string or a heredoc line, so
    # truncate_tables, :truncate and %i[truncate ...] are not counted.
    # Both allowed ones clear the separate Timekeeping database after a collect.
    Rule.new(name: "raw SQL truncate", pattern: /(?:["'`]|^\s*)truncate\s+(?:table\s+)?["#\w]/i,
             allowed: { TIMEKEEPING_RESET_FILE => 1, RUNTIME_QUEUES_FILE => 1 }, only_in: nil),
    Rule.new(name: "raw SQL queue delete", pattern: /\bdelete\s+from\s+"?solid_queue_/i,
             allowed: {}, only_in: nil)
  ].freeze

  module_function

  # sources maps a repository-relative path to its text. Returns one
  # "rule: path:line" entry for each matching line past the file's allowance.
  def offenses(sources)
    RULES.flat_map do |rule|
      sources.flat_map do |path, text|
        next [] if rule.only_in && rule.only_in != path

        hits = matching_lines(text, rule.pattern)
        hits.drop(rule.allowed.fetch(path, 0)).map { |number| "#{rule.name}: #{path}:#{number}" }
      end
    end
  end

  def matching_lines(text, pattern)
    text.each_line.with_index(1).filter_map do |line, number|
      number if !line.lstrip.start_with?("#") && line.match?(pattern)
    end
  end

  # Every spec file except the one that defines this scan.
  def spec_sources(skip:)
    Dir.glob(Rails.root.join("spec/**/*.rb")).each_with_object({}) do |absolute, sources|
      next if File.expand_path(absolute) == File.expand_path(skip)

      sources[Pathname(absolute).relative_path_from(Rails.root).to_s] = File.read(absolute)
    end
  end
end

RSpec.describe TestDatabaseCleanupResetSiteScan do
  # "A new truncate site that leaves out the call erases executions with no record, and nothing catches it."
  it "reports nothing for the spec files as they stand" do
    expect(described_class.offenses(described_class.spec_sources(skip: __FILE__))).to eq([])
  end

  it "reports a new raw SQL TRUNCATE with its path and line" do
    sources = { "spec/support/new_reset.rb" => "x = 1\nActiveRecord::Base.connection.execute(\"TRUNCATE users\")\n" }

    expect(described_class.offenses(sources)).to eq(["raw SQL truncate: spec/support/new_reset.rb:2"])
  end

  it "reports a lower-case truncate and a raw delete from a solid_queue_ table" do
    sources = {
      "spec/support/new_reset.rb" => "execute(\"truncate solid_queue_jobs\")\nexecute(\"DELETE FROM solid_queue_jobs\")\n"
    }

    expect(described_class.offenses(sources)).to eq(
      ["raw SQL truncate: spec/support/new_reset.rb:1", "raw SQL queue delete: spec/support/new_reset.rb:2"]
    )
  end

  it "reports a direct TestDatabaseCleanup.before_reset! call in a new file" do
    sources = { "spec/support/new_reset.rb" => "TestDatabaseCleanup.before_reset!\n" }

    expect(described_class.offenses(sources)).to eq(["direct collect: spec/support/new_reset.rb:1"])
  end

  it "reports a second DatabaseCleaner.clean_with and a second bare collect in the wrapper file" do
    text = <<~RUBY
      def before_reset!
      end

      def clean_with!(strategy, **options)
        before_reset!
        DatabaseCleaner.clean_with(strategy, **options)
      end

      def another_reset!
        before_reset!
        DatabaseCleaner.clean_with :truncation
      end
    RUBY

    expect(described_class.offenses("spec/support/database_cleaner.rb" => text)).to eq(
      [
        "direct DatabaseCleaner.clean_with: spec/support/database_cleaner.rb:11",
        "bare collect: spec/support/database_cleaner.rb:10"
      ]
    )
  end

  it "reports a TRUNCATE past the one the runtime queues spec may hold" do
    text = "timekeeping.exec(\"TRUNCATE \#{tables}\")\nconnection.execute(\"TRUNCATE \#{queue_tables}\")\n"

    expect(described_class.offenses("spec/timekeeping/runtime_queues_spec.rb" => text))
      .to eq(["raw SQL truncate: spec/timekeeping/runtime_queues_spec.rb:2"])
  end

  it "ignores words and symbols that only look like truncate" do
    text = "truncate_tables(connection)\nsteps << :truncate }\nit \"truncates long names\" do\n" \
           "expect(steps).to eq(%i[truncate clean_monolith example])\n"

    expect(described_class.offenses("spec/support/other.rb" => text)).to eq([])
  end
end

RSpec.describe TestDatabaseCleanup do
  context "more tests 10" do
    it "clean_with! collects before it deletes and passes the strategy and every option through unchanged" do
      steps = []
      received = []
      allow(described_class).to receive(:before_reset!) { steps << :collect }
      allow(DatabaseCleaner).to receive(:clean_with) do |strategy, **options|
        steps << :delete
        received << [strategy, options]
      end

      # "Add TestDatabaseCleanup.clean_with!(strategy, \*\*options), which calls before_reset! and then DatabaseCleaner.clean_with."
      described_class.clean_with!(:deletion, except: %w[a b], pre_count: true, reset_ids: false)

      expect(steps).to eq(%i[collect delete])
      expect(received).to eq([[:deletion, { except: %w[a b], pre_count: true, reset_ids: false }]])
    end
  end

  context "more tests 11" do
    it "clean_with! adds no default options to a truncation that keeps only ar_internal_metadata" do
      received = []
      allow(described_class).to receive(:before_reset!)
      allow(DatabaseCleaner).to receive(:clean_with) { |strategy, **options| received << [strategy, options] }

      described_class.clean_with!(:truncation, except: %w[ar_internal_metadata])

      expect(received).to eq([[:truncation, { except: %w[ar_internal_metadata] }]])
    end
  end

  context "more tests 17" do
    # "Every monolith truncate and delete site calls one TestDatabaseCleanup wrapper that runs before_reset! and then DatabaseCleaner.clean_with, and no site calls before_reset! on its own."
    it "the committed data reset and delete_all_committed! delete through clean_with! with their own options" do
      calls = []
      allow(described_class).to receive(:clean_with!) { |strategy, **options| calls << [strategy, options] }
      allow(described_class).to receive(:before_reset!) { calls << :direct_collect }
      allow(DatabaseCleaner).to receive(:clean_with) { calls << :direct_delete }
      allow(TimekeepingOwnership).to receive(:ensure_initial!)

      CommittedDataMode.reset_database
      described_class.delete_all_committed!

      expect(calls).to eq([
        [:deletion, { except: %w[ar_internal_metadata schema_migrations] }],
        [:deletion, { except: %w[ar_internal_metadata schema_migrations], pre_count: true, reset_ids: false }]
      ])
    end
  end

  context "more tests 18" do
    # "Every monolith truncate and delete site calls one TestDatabaseCleanup wrapper that runs before_reset! and then DatabaseCleaner.clean_with, and no site calls before_reset! on its own."
    it "no spec file outside the Timekeeping database reset calls the collect hook or DatabaseCleaner.clean_with directly" do
      hook_call = ["TestDatabaseCleanup", "before_reset!"].join(".")
      clean_call = ["DatabaseCleaner", "clean_with"].join(".")
      timekeeping_reset = "spec/support/timekeeping/timekeeping_database_reset.rb"
      hook_callers = []
      clean_callers = []

      Dir.glob(Rails.root.join("spec/**/*.rb")).each do |path|
        next if File.expand_path(path) == File.expand_path(__FILE__)

        relative = Pathname(path).relative_path_from(Rails.root).to_s
        File.foreach(path).with_index(1) do |line, number|
          hook_callers << "#{relative}:#{number}" if line.include?(hook_call) && relative != timekeeping_reset
          clean_callers << relative if line.include?(clean_call)
        end
      end

      expect(hook_callers).to eq([])
      expect(clean_callers).to eq(["spec/support/database_cleaner.rb"])
    end
  end

  context "more tests 19" do
    # "A new truncate site that leaves out the call erases executions with no record, and nothing catches it."
    it "no spec file truncates monolith tables with raw SQL outside the two Timekeeping database truncates" do
      # SQL statements only, so method names such as truncate_tables, symbols
      # such as :truncate and words such as "truncated" are not counted.
      raw_truncate = TestDatabaseCleanupResetSiteScan::RULES.find { |rule| rule.name == "raw SQL truncate" }.pattern
      raw_queue_delete = TestDatabaseCleanupResetSiteScan::RULES.find { |rule| rule.name == "raw SQL queue delete" }.pattern
      counts = Hash.new(0)

      Dir.glob(Rails.root.join("spec/**/*.rb")).each do |path|
        next if File.expand_path(path) == File.expand_path(__FILE__)

        relative = Pathname(path).relative_path_from(Rails.root).to_s
        File.foreach(path) do |line|
          next if line.lstrip.start_with?("#")

          counts[relative] += 1 if line.match?(raw_truncate) || line.match?(raw_queue_delete)
        end
      end

      expect(counts).to eq(
        "spec/support/timekeeping/timekeeping_database_reset.rb" => 1,
        "spec/timekeeping/runtime_queues_spec.rb" => 1
      )
    end
  end

  context "more tests 20" do
    # "Every monolith truncate and delete site calls one TestDatabaseCleanup wrapper that runs before_reset! and then DatabaseCleaner.clean_with, and no site calls before_reset! on its own."
    # When collection fails, the delete must not run: deleting anyway would erase executions with no record.
    it "clean_with! deletes nothing when before_reset! fails to collect" do
      collect_failure = Class.new(StandardError)
      allow(described_class).to receive(:before_reset!).and_raise(collect_failure, "runtime still live")
      allow(DatabaseCleaner).to receive(:clean_with)

      expect { described_class.clean_with!(:truncation, except: %w[ar_internal_metadata]) }
        .to raise_error(collect_failure, "runtime still live")
      expect(DatabaseCleaner).not_to have_received(:clean_with)
    end
  end

  context "more tests 21" do
    # "Every monolith truncate and delete site calls one TestDatabaseCleanup wrapper that runs before_reset! and then DatabaseCleaner.clean_with, and no site calls before_reset! on its own."
    # Back-to-back resets (a before hook then an after hook) must each collect before their own delete,
    # not share one collect or delete twice per call.
    it "clean_with! collects once before each delete when called twice in a row" do
      steps = []
      allow(described_class).to receive(:before_reset!) { steps << :collect }
      allow(DatabaseCleaner).to receive(:clean_with) { |strategy, **options| steps << [:delete, strategy, options] }

      described_class.clean_with!(:truncation, except: %w[ar_internal_metadata schema_migrations])
      described_class.clean_with!(:deletion, except: %w[ar_internal_metadata schema_migrations], pre_count: true, reset_ids: false)

      expect(steps).to eq(
        [
          :collect,
          [:delete, :truncation, { except: %w[ar_internal_metadata schema_migrations] }],
          :collect,
          [:delete, :deletion, { except: %w[ar_internal_metadata schema_migrations], pre_count: true, reset_ids: false }]
        ]
      )
    end
  end

  context "more tests 22" do
    # "Every monolith truncate and delete site calls one TestDatabaseCleanup wrapper that runs before_reset! and then DatabaseCleaner.clean_with, and no site calls before_reset! on its own."
    # The runtime queues hook truncates only the solid_queue_ tables; an added except: default would
    # change what that reset deletes.
    it "clean_with! with only an only: list passes no except: default that would widen or narrow the delete" do
      steps = []
      allow(described_class).to receive(:before_reset!) { steps << :collect }
      allow(DatabaseCleaner).to receive(:clean_with) { steps << :delete }

      described_class.clean_with!(:truncation, only: %w[solid_queue_jobs solid_queue_ready_executions])

      expect(steps).to eq(%i[collect delete])
      expect(DatabaseCleaner).to have_received(:clean_with)
        .with(:truncation, only: %w[solid_queue_jobs solid_queue_ready_executions]).once
    end
  end
end
