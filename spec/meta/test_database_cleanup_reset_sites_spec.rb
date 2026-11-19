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
  QUEUE_LEDGER_ROWS_PROBE_FILE = "spec/fixtures/timekeeping_harness/queue_ledger_rows_probe.rb"

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
    # A TRUNCATE that ends its line counts too, because SQL often puts the
    # table names on the next line.
    # Both allowed ones clear the separate Timekeeping database after a collect.
    Rule.new(name: "raw SQL truncate", pattern: /(?:["'`]|^\s*)truncate(?:\s+(?:table\s+)?["#\w]|\s*$)/i,
             allowed: { TIMEKEEPING_RESET_FILE => 1, RUNTIME_QUEUES_FILE => 1 }, only_in: nil),
    Rule.new(name: "raw SQL queue delete", pattern: /\bdelete\s+from\s+"?solid_queue_/i,
             allowed: {}, only_in: nil),
    # Rails' own truncate on a connection, such as connection.truncate_tables(...).
    # A bare truncate_tables(connection) is the Timekeeping reset's private helper.
    Rule.new(name: "connection truncate", pattern: /\.truncate_tables?\b/,
             allowed: {}, only_in: nil),
    # The rows probe deletes chosen queue rows on purpose to check what the
    # ledger records; it is not a reset site.
    Rule.new(name: "Solid Queue model delete", pattern: /\bSolidQueue::\w+\b.*\.(?:delete_all|destroy_all)\b/,
             allowed: { QUEUE_LEDGER_ROWS_PROBE_FILE => 4 }, only_in: nil)
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

  # Returns the number of the first line of each statement that matches.
  def matching_lines(text, pattern)
    statements(text).filter_map do |number, statement|
      number if !statement.lstrip.start_with?("#") && statement.match?(pattern)
    end
  end

  # Joins a method chain split across lines (a line that starts with ".")
  # onto the line its receiver is on, so SolidQueue::Job.where(...) followed
  # by .delete_all on the next line is matched as one call. A comment line is
  # never a receiver, so a chain is not hidden behind one.
  def statements(text)
    text.each_line.with_index(1).each_with_object([]) do |(line, number), joined|
      if line.lstrip.start_with?(".") && joined.any? && !joined.last[1].lstrip.start_with?("#")
        joined.last[1] = "#{joined.last[1].rstrip} #{line.strip}"
      else
        joined << [number, line.chomp]
      end
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

  it "reports a raw SQL TRUNCATE whose table names are on the next line" do
    sources = {
      "spec/support/new_reset.rb" => "ActiveRecord::Base.connection.execute(<<~SQL)\n  TRUNCATE\n    solid_queue_jobs\nSQL\n" \
                                     "connection.execute(\"TRUNCATE\n  solid_queue_jobs\")\n"
    }

    expect(described_class.offenses(sources)).to eq(
      ["raw SQL truncate: spec/support/new_reset.rb:2", "raw SQL truncate: spec/support/new_reset.rb:5"]
    )
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

  it "reports a Rails connection truncate and a Solid Queue model delete" do
    sources = {
      "spec/support/new_reset.rb" => "ActiveRecord::Base.connection.truncate_tables(\"solid_queue_jobs\")\n" \
                                     "SolidQueue::Job.where(queue_name: \"default\").delete_all\n" \
                                     "SolidQueue::FailedExecution.destroy_all\n"
    }

    expect(described_class.offenses(sources)).to eq(
      [
        "connection truncate: spec/support/new_reset.rb:1",
        "Solid Queue model delete: spec/support/new_reset.rb:2",
        "Solid Queue model delete: spec/support/new_reset.rb:3"
      ]
    )
  end

  it "reports a Solid Queue model delete past the four the rows probe may hold" do
    text = "SolidQueue::Job.delete_all\n" * 5

    expect(described_class.offenses("spec/fixtures/timekeeping_harness/queue_ledger_rows_probe.rb" => text))
      .to eq(["Solid Queue model delete: spec/fixtures/timekeeping_harness/queue_ledger_rows_probe.rb:5"])
  end

  it "reports a Solid Queue delete chain split across lines at its receiver's line" do
    sources = { "spec/support/new_reset.rb" => "x = 1\nSolidQueue::Job.where.not(finished_at: nil)\n  .delete_all\n" }

    expect(described_class.offenses(sources)).to eq(["Solid Queue model delete: spec/support/new_reset.rb:2"])
  end

  # An allowance that no longer matches anything would let a new site take
  # its place unnoticed, so each allowed file must still hold exactly that many.
  it "finds exactly the allowed number of matches in each allowed file" do
    sources = described_class.spec_sources(skip: __FILE__)
    counts = described_class::RULES.flat_map do |rule|
      rule.allowed.map do |path, allowed|
        [rule.name, path, described_class.matching_lines(sources.fetch(path), rule.pattern).size, allowed]
      end
    end

    expect(counts.map { |name, path, found, _allowed| [name, path, found] })
      .to eq(counts.map { |name, path, _found, allowed| [name, path, allowed] })
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
