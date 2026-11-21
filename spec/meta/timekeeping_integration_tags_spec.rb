# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimekeepingIntegrationTags do
  describe ".violations tag rule" do
    # "An example lacks the tag when neither it nor an enclosing group sets `committed_data: true`, or when the nearest setting is `false` or `nil`. The tag may sit on any level."
    it "flags an example whose nearest committed_data setting is false or nil" do
      source = <<~RUBY
        RSpec.describe "relay", committed_data: true do
          it "keeps the tag" do
          end

          it "turns it off", committed_data: false do
          end

          context "nested", committed_data: nil do
            it "inherits nil" do
            end

            it "turns it back on", committed_data: true do
            end
          end
        end
      RUBY

      violations = described_class.violations("spec/integration/timekeeping/example_spec.rb", source)

      expect(violations.map { |violation| [violation.kind, violation.line] })
        .to contain_exactly([:missing_committed_data, 5], [:missing_committed_data, 9])
      expect(violations.map(&:path)).to all(eq("spec/integration/timekeeping/example_spec.rb"))
    end

    it "flags an example whose nearest committed_data setting is false or nil inside a tagged group" do
      source = <<~RUBY
        RSpec.describe "relay", committed_data: true do
          context "inner", committed_data: false do
            it "runs with the override" do
            end
          end

          it "runs with nil", committed_data: nil do
          end

          it "runs tagged" do
          end
        end
      RUBY

      violations = described_class.violations("spec/integration/timekeeping/example_spec.rb", source)

      expect(violations.map { |violation| [violation.kind, violation.line] })
        .to contain_exactly([:missing_committed_data, 3], [:missing_committed_data, 7])
    end

    it "flags untagged examples and accepts individually tagged ones" do
      untagged = <<~RUBY
        RSpec.describe "relay" do
          it "has no tag" do
          end
        end
      RUBY
      individually_tagged = <<~RUBY
        RSpec.describe "relay" do
          it "first", committed_data: true do
          end

          specify "second", committed_data: true do
          end
        end
      RUBY
      symbol_tagged = <<~RUBY
        describe "relay", :committed_data do
          context "inner" do
            it "inherits the symbol tag" do
            end
          end
        end
      RUBY
      aliased = <<~RUBY
        RSpec.describe "relay" do
          fit "focused but untagged" do
          end
        end
      RUBY

      expect(described_class.violations("a_spec.rb", untagged).map { |v| [v.kind, v.line] })
        .to eq([[:missing_committed_data, 2]])
      expect(described_class.violations("b_spec.rb", individually_tagged)).to eq([])
      expect(described_class.violations("c_spec.rb", symbol_tagged)).to eq([])
      expect(described_class.violations("d_spec.rb", aliased).map(&:kind)).to eq([:missing_committed_data])
    end

    it "flags untagged focus, pending and skip examples, and reads example_group as a group" do
      source = <<~RUBY
        RSpec.describe "relay" do
          focus "focused" do
          end

          pending "not yet" do
          end

          skip "skipped" do
          end

          example_group "tagged group", committed_data: true do
            it "inherits the tag" do
            end
          end
        end
      RUBY

      violations = described_class.violations("e_spec.rb", source)

      expect(violations.map { |v| [v.kind, v.line] })
        .to eq([[:missing_committed_data, 2], [:missing_committed_data, 5], [:missing_committed_data, 8]])
    end

    it "reads skip and pending inside hooks and example bodies as runtime calls, not examples" do
      source = <<~RUBY
        RSpec.describe "relay" do
          before { skip "requires live" }
          let(:value) { pending "not yet" }

          it "works", committed_data: true do
            skip "later"
            TimekeepingHandoffFakeRelay.new(store: nil)
          end
        end
      RUBY

      violations = described_class.violations("f_spec.rb", source)

      # The fake reference inside the example body is still checked.
      expect(violations.map { |v| [v.kind, v.line] }).to eq([[:loads_handoff_fakes, 7]])
    end
  end

  describe ".violations handoff fakes rule" do
    # "A file loads the fakes when it calls `require`, `require_relative` or `load` naming handoff_fakes.rb, or when it references a constant that file defines. Read those constants by parsing that file. A comment that only mentions the fakes is not a violation."
    it "flags require, require_relative and load of handoff_fakes but not a comment or plain string" do
      tagged_example = <<~RUBY
        RSpec.describe "relay", committed_data: true do
          it "runs" do
          end
        end
      RUBY
      loading_calls = [
        'require "support/timekeeping/handoff_fakes"',
        'require_relative "../../support/timekeeping/handoff_fakes.rb"',
        'load "spec/support/timekeeping/handoff_fakes.rb"',
        'require_relative "../../support/timekeeping/handoff_fakes"',
        'Kernel.require "support/timekeeping/handoff_fakes"',
        'Kernel.require_relative "../../support/timekeeping/handoff_fakes.rb"',
        '::Kernel.load "spec/support/timekeeping/handoff_fakes.rb"'
      ]

      loading_calls.each do |call|
        kinds = described_class.violations("x_spec.rb", "#{call}\n#{tagged_example}").map(&:kind)
        expect(kinds).to eq([:loads_handoff_fakes]), call
      end

      comment_only = "# Uses real databases, not spec/support/timekeeping/handoff_fakes.rb.\n#{tagged_example}"
      plain_string = "NOTE = \"spec/support/timekeeping/handoff_fakes.rb\"\n#{tagged_example}"
      expect(described_class.violations("x_spec.rb", comment_only)).to eq([])
      expect(described_class.violations("x_spec.rb", plain_string)).to eq([])
    end

    it "flags each form of reference to a constant handoff_fakes defines" do
      references = [
        "TimekeepingHandoffFakeRelay.new(store: nil)",
        "::TimekeepingHandoffFakeRelay.new(store: nil)",
        "Object::TimekeepingHandoffFakeRelay.new(store: nil)",
        "TimekeepingHandoffFakes::RecordingAdmission.new"
      ]

      references.each do |reference|
        source = <<~RUBY
          RSpec.describe "relay", committed_data: true do
            it "uses a fake" do
              #{reference}
            end
          end
        RUBY
        violations = described_class.violations("x_spec.rb", source)
        expect(violations.map { |v| [v.kind, v.line] }).to eq([[:loads_handoff_fakes, 3]]), reference
      end

      clean_lines = [
        "Timekeeping::SeedDispositionRecorder::DEFAULT_PATH",
        "# uses spec/support/timekeeping/handoff_fakes.rb TimekeepingHandoffFakeRelay",
        "note = \"spec/support/timekeeping/handoff_fakes.rb\""
      ]
      clean_lines.each do |line|
        source = <<~RUBY
          RSpec.describe "relay", committed_data: true do
            it "uses real code" do
              #{line}
            end
          end
        RUBY
        expect(described_class.violations("x_spec.rb", source)).to eq([]), line
      end
    end

    it "matches a fake declared compactly inside a real namespace by its full name only" do
      compact_fakes = described_class.handoff_fake_constants("class Timekeeping::IntegrationTagsCompactFake\nend\n")
      source_using = lambda do |reference|
        "RSpec.describe \"relay\", committed_data: true do\n  it \"runs\" do\n    #{reference}\n  end\nend\n"
      end

      flagged = described_class.violations(
        "x_spec.rb", source_using.call("Timekeeping::IntegrationTagsCompactFake.new"), fake_constants: compact_fakes
      )
      real = described_class.violations(
        "x_spec.rb", source_using.call("Timekeeping::SeedDispositionRecorder::DEFAULT_PATH"), fake_constants: compact_fakes
      )

      expect(flagged.map { |v| [v.kind, v.line] }).to eq([[:loads_handoff_fakes, 3]])
      expect(real).to eq([])
    end
  end

  describe ".handoff_fake_constants" do
    # "Read those constants by parsing that file." A renamed or emptied fakes
    # file must fail the check rather than let every reference pass.
    it "reads top-level and nested fake constants by parsing handoff_fakes and refuses an empty set" do
      constants = described_class.handoff_fake_constants

      expect(constants).to include(
        "TimekeepingHandoffFakeRelay",
        "TimekeepingHandoffFakes",
        "TimekeepingHandoffFakes::RecordingAdmission",
        "TimekeepingHandoffFakes::InMemoryTimekeepingStore",
        "TimekeepingHandoffFakes::NoOpSettle"
      )

      custom = described_class.handoff_fake_constants("module OtherFakes\n  class Inner\n  end\nend\n")
      expect(custom.to_a).to contain_exactly("OtherFakes", "OtherFakes::Inner")

      expect { described_class.handoff_fake_constants("# only a comment\n") }.to raise_error(ArgumentError)
    end
  end

  describe "the spec/integration/timekeeping tree" do
    # "spec/meta/timekeeping_integration_tags_spec.rb fails when an example under spec/integration/timekeeping lacks `committed_data` or loads spec/support/timekeeping/handoff_fakes.rb, and passes on the finished tree"
    it "every spec under spec/integration/timekeeping carries committed_data and never loads the handoff fakes" do
      paths = Dir[Rails.root.join("spec/integration/timekeeping/**/*_spec.rb").to_s]
      names = paths.map { |path| File.basename(path) }

      expect(names).to include("local_relay_spec.rb", "alerts_live_spec.rb")

      violations = paths.flat_map { |path| described_class.violations(path, File.read(path)) }
      report = violations.map { |v| "#{v.path}:#{v.line} #{v.kind} #{v.detail}" }.join("\n")
      expect(violations).to be_empty, report
    end
  end

  context "more tests 2" do
  it "accepts committed_data: true wrapped onto a second line on a group and on an example, and still flags a wrapped false" do
    wrapped_group = <<~RUBY
      RSpec.describe "relay", :integrated_runtime, :two_tenant_seed,
                     committed_data: true do
        it "inherits the wrapped tag" do
        end
      end
    RUBY
    wrapped_example = <<~RUBY
      RSpec.describe "relay" do
        it "carries a wrapped tag",
           committed_data: true do
        end
      end
    RUBY
    wrapped_false = <<~RUBY
      RSpec.describe "relay", :integrated_runtime,
                     committed_data: false do
        it "is untagged" do
        end
      end
    RUBY

    # "The tag meta spec (spec/meta/timekeeping_integration_tags_spec.rb) must accept `committed_data: true` even when it wraps onto a second line."
    expect(described_class.violations("wrapped_group_spec.rb", wrapped_group)).to eq([])
    expect(described_class.violations("wrapped_example_spec.rb", wrapped_example)).to eq([])
    expect(described_class.violations("wrapped_false_spec.rb", wrapped_false).map { |v| [v.kind, v.line] })
      .to eq([[:missing_committed_data, 3]])
  end
  end

  context "more tests 3" do
  it "money guard and handoff sequence specs exist, carry committed_data, never load the handoff fakes, and run on the integrated runtime" do
    paths = %w[money_guard_spec.rb handoff_sequence_spec.rb].map do |name|
      Rails.root.join("spec/integration/timekeeping", name)
    end

    paths.each do |path|
      expect(File).to exist(path), path.to_s
      source = File.read(path)

      # "Every example carries `committed_data` and no example loads spec/support/timekeeping/handoff_fakes.rb"
      violations = described_class.violations(path.to_s, source)
      expect(violations).to eq([]), violations.map { |v| "#{v.line} #{v.kind} #{v.detail}" }.join("\n")

      # "Every live example here runs under the teardown queue ledger (`spec/support/timekeeping/queue_ledger.rb`), and the suite fails if a job from a non-dedicated queue ran"
      # The ledger activates only when IntegratedRuntime.start runs, which the :integrated_runtime tag triggers.
      expect(source).to include(":integrated_runtime"), path.to_s
      expect(source).not_to include("TimekeepingLiveInstance"), path.to_s
    end
  end
  end

  context "more tests 4" do
require "prism"
  it "the live tenant_counts group in the live handoff meta spec carries integrated_runtime and committed_data and adds no reset of its own" do
    path = Rails.root.join("spec/meta/timekeeping_live_handoff_spec.rb")
    expect(File).to exist(path)
    source = File.read(path)

    calls = []
    pending_nodes = [Prism.parse(source).value]
    until pending_nodes.empty?
      node = pending_nodes.shift
      calls << node if node.is_a?(Prism::CallNode)
      pending_nodes.concat(node.compact_child_nodes)
    end
    live_groups = calls.select do |call|
      %i[describe context].include?(call.name) &&
        call.arguments&.arguments&.any? { |argument| argument.is_a?(Prism::SymbolNode) && argument.unescaped == "integrated_runtime" }
    end

    # "The live `tenant_counts` meta example carries `committed_data` and `:integrated_runtime` and follows the database reset rule, though it lives under `spec/meta`"
    expect(live_groups).not_to be_empty
    expect(live_groups.map(&:slice).join("\n")).to include("timekeeping_counts").or include("tenant_counts")
    live_groups.each do |group|
      expect(described_class.violations(path.to_s, group.slice)).to eq([])
    end

    # "Every database reset these examples add calls `TestDatabaseCleanup.before_reset!` first or goes through `TimekeepingDatabaseReset.reset!`"
    # A direct before_reset! outside timekeeping_database_reset.rb fails the reset-site scan, and a reset
    # while the runtime is live raises, so the file adds none of these.
    expect(source).not_to include("before_reset!")
    expect(source).not_to match(/\bTRUNCATE\b/i)
    expect(source).not_to include("db:prepare")
  end
  end
end
