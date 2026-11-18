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
        'require_relative "../../support/timekeeping/handoff_fakes"'
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
end
