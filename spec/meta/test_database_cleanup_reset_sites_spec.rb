require "rails_helper"

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

  context "more tests 12" do
  it "clean_with! deletes nothing when collecting the queue executions fails" do
    collect_failure = Class.new(StandardError)
    allow(described_class).to receive(:before_reset!).and_raise(collect_failure)
    allow(DatabaseCleaner).to receive(:clean_with)

    expect { described_class.clean_with!(:truncation, except: %w[ar_internal_metadata schema_migrations]) }
      .to raise_error(collect_failure)
    expect(DatabaseCleaner).not_to have_received(:clean_with)
  end
  end

  context "more tests 13" do
  it "no spec file outside the wrapper calls TestDatabaseCleanup.before_reset! or DatabaseCleaner.clean_with directly" do
    # Built from pieces so this file's own text never matches.
    direct_collect = ["TestDatabaseCleanup", ".before_reset!"].join
    direct_delete = ["DatabaseCleaner", ".clean_with"].join
    # Resets the separate Timekeeping database through its before_truncate: hook.
    collect_allowed = ["spec/support/timekeeping/timekeeping_database_reset.rb"]
    this_file = Pathname.new(__FILE__).relative_path_from(Rails.root).to_s

    collect_offenders = []
    delete_hits = []
    Dir.glob(Rails.root.join("spec/**/*.rb")).each do |absolute|
      path = Pathname.new(absolute).relative_path_from(Rails.root).to_s
      next if path == this_file

      File.foreach(absolute).with_index(1) do |line, number|
        collect_offenders << "#{path}:#{number}" if line.include?(direct_collect) && !collect_allowed.include?(path)
        delete_hits << path if line.include?(direct_delete)
      end
    end

    # "Every monolith truncate and delete site calls one TestDatabaseCleanup wrapper that runs before_reset! and then DatabaseCleaner.clean_with, and no site calls before_reset! on its own."
    expect(collect_offenders).to eq([])
    expect(delete_hits).to eq(["spec/support/database_cleaner.rb"])
  end
  end

  context "more tests 14" do
  # "Add TestDatabaseCleanup.clean_with!(strategy, \*\*options), which calls before_reset! and then DatabaseCleaner.clean_with."
  it "clean_with! collects before it deletes and passes the strategy and every option through unchanged" do
    steps = []
    received = []
    allow(described_class).to receive(:before_reset!) { steps << :collect }
    allow(DatabaseCleaner).to receive(:clean_with) do |strategy, **options|
      steps << :delete
      received << [strategy, options]
    end

    described_class.clean_with!(:deletion, except: %w[a b], pre_count: true, reset_ids: false)

    expect(steps).to eq(%i[collect delete])
    expect(received).to eq([[:deletion, { except: %w[a b], pre_count: true, reset_ids: false }]])
  end
  end

  context "more tests 15" do
  it "clean_with! adds no default options to a truncation that keeps only ar_internal_metadata" do
    received = []
    allow(described_class).to receive(:before_reset!)
    allow(DatabaseCleaner).to receive(:clean_with) { |strategy, **options| received << [strategy, options] }

    described_class.clean_with!(:truncation, except: %w[ar_internal_metadata])

    expect(received).to eq([[:truncation, { except: %w[ar_internal_metadata] }]])
  end
  end

  context "more tests 16" do
  it "clean_with! deletes nothing when the collect step raises" do
    collect_failure = Class.new(StandardError)
    allow(described_class).to receive(:before_reset!).and_raise(collect_failure)
    allow(DatabaseCleaner).to receive(:clean_with)

    expect { described_class.clean_with!(:truncation, except: %w[ar_internal_metadata]) }
      .to raise_error(collect_failure)
    expect(DatabaseCleaner).not_to have_received(:clean_with)
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
    raw_truncate = Regexp.new(["TRUN", "CATE"].join, Regexp::IGNORECASE)
    raw_queue_delete = Regexp.new(["DELETE FROM ", "solid_queue_"].join, Regexp::IGNORECASE)
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
