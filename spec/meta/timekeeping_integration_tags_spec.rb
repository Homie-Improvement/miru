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
    # "A group written `xdescribe` or `xcontext`, or a group carrying `skip:` or `pending:` metadata, disables every example under it: pass a disabled flag down the walk, the way `walk` already passes the committed_data setting down."
    it "example_names leaves out examples under xdescribe, xcontext and skip or pending groups at any depth" do
      source = <<~RUBY
      RSpec.describe "relay" do
        it "Kept top" do
        end

        context "outer" do
          context "inner" do
            it "Kept nested" do
            end
          end
        end

        xcontext "off" do
          it "In xcontext" do
          end
        end

        xdescribe "off too" do
          context "plain" do
            it "Deep in xdescribe" do
            end
          end
        end

        context "skipped", skip: true do
          it "In skip group" do
          end
        end

        describe "pending group", pending: true do
          it "In pending group" do
          end
        end
      end
      RUBY

      names = described_class.example_names(source)

      expect(names).to eq(["Kept top", "Kept nested"])
      expect(names).to be_frozen
    end
  end

  context "more tests 3" do
    # "It leaves out x-prefixed calls (`xit`, `xspecify`, `xexample`), `skip`, `pending`, and calls carrying `skip:` or `pending:` metadata, because they are not passing examples."
    it "example_names leaves out xit, skip-tagged, pending, blockless and in-body strings beside a kept example" do
      source = <<~RUBY
      RSpec.describe "relay" do
        before do
          it "In before" do
          end
        end

        xit "A" do
        end

        it "B", skip: true do
        end

        pending "C" do
        end

        it "Relay down"

        specify "Kept" do
          it "In body" do
          end
        end
      end
      RUBY

      expect(described_class.example_names(source)).to eq(["Kept"])
    end
  end

  context "more tests 4" do
    # "A name that is not a plain string literal (for example an interpolated `it "#{x} y"`) raises ArgumentError naming its line."
    it "example_names raises ArgumentError naming the line of an interpolated example name" do
      source = <<~'RUBY'
      RSpec.describe "relay" do
        x = "Relay"
        it "#{x} y" do
        end
      end
      RUBY

      expect { described_class.example_names(source) }.to raise_error(ArgumentError, /line 3\b/)
    end
  end

  context "more tests 5" do
    # "Keep the existing `violations` behaviour unchanged."
    it "violations still flags untagged examples that example_names leaves out" do
      source = <<~RUBY
      RSpec.describe "relay" do
        xdescribe "off" do
          it "inside xdescribe" do
          end
        end

        it "blockless"

        it "kept", committed_data: true do
        end
      end
      RUBY

      expect(described_class.example_names(source)).to eq(["kept"])

      violations = described_class.violations("spec/integration/timekeeping/example_spec.rb", source)
      expect(violations.map { |violation| [violation.kind, violation.line] })
        .to contain_exactly([:missing_committed_data, 3], [:missing_committed_data, 7])
    end
  end

  context "more tests 6" do
    # "A group written `xdescribe` or `xcontext`, or a group carrying `skip:` or `pending:` metadata, disables every example under it: pass a disabled flag down the walk, the way `walk` already passes the committed_data setting down."
    it "example_names keeps an xdescribe disabled through two plain inner groups" do
      source = <<~RUBY
      RSpec.describe "relay" do
        xdescribe "off" do
          context "inner" do
            describe "deeper" do
              it "Hidden deep" do
              end
            end
          end
        end

        RSpec.xdescribe "off through RSpec" do
          context "inner" do
            it "Hidden via RSpec receiver" do
            end
          end
        end

        context "on", skip: "later" do
          context "inner" do
            it "Hidden under skip" do
            end
          end
        end

        context "control" do
          it "Visible control" do
          end
        end
      end
      RUBY

      expect(described_class.example_names(source)).to eq(["Visible control"])
    end
  end

  context "more tests 7" do
    # "An xit, skip, pending or non-literal example name, or an example inside an xdescribe, xcontext or skipped group, never counts as covering a row"
    it "example_names leaves out a blockless example that RSpec reports as pending" do
      source = <<~RUBY
      RSpec.describe "relay" do
        it "Relay down"
        specify "Relay down twice"

        it "Relay down implemented" do
        end
      end
      RUBY

      expect(described_class.example_names(source)).to eq(["Relay down implemented"])
    end
  end

  context "more tests 8" do
    # "A name that is not a plain string literal (for example an interpolated `it \"#{x} y\"`) raises ArgumentError naming its line."
    it "example_names raises naming the line for a concatenated, constant or symbol example name" do
      concatenated = <<~RUBY
      RSpec.describe "relay" do
        it "Relay" " down" do
        end
      end
      RUBY
      constant = <<~RUBY
      RSpec.describe "relay" do
        it "Visible" do
        end

        it CASE_NAME do
        end
      end
      RUBY
      symbol = <<~RUBY
      RSpec.describe "relay" do
        context "inner" do
          it :relay_down do
          end
        end
      end
      RUBY

      expect { described_class.example_names(concatenated) }.to raise_error(ArgumentError, /line 2\b/)
      expect { described_class.example_names(constant) }.to raise_error(ArgumentError, /line 5\b/)
      expect { described_class.example_names(symbol) }.to raise_error(ArgumentError, /line 3\b/)
    end
  end

  context "more tests 9" do
    it "example_names result does not change when the source string is mutated afterwards" do
      source = +<<~RUBY
      RSpec.describe "relay" do
        it "Relay down" do
        end
      end
      RUBY

      names = described_class.example_names(source)
      source.replace("")

      expect(names).to eq(["Relay down"])
      expect(names).to be_frozen
      expect(names).to all(be_frozen)
    end
  end

  describe ".example_names edge forms" do
    it "leaves out focused examples and groups marked with a bare :skip or :pending symbol" do
      source = <<~RUBY
        RSpec.describe "relay" do
          fit "D" do
          end

          context "bare skip", :skip do
            it "Under bare skip" do
            end
          end

          context "bare pending", :pending do
            it "Under bare pending" do
            end
          end

          example "Counted control" do
          end
        end
      RUBY

      expect(described_class.example_names(source)).to eq(["Counted control"])
    end

    it "raises naming the line of an example that has a block but no name" do
      source = <<~RUBY
        RSpec.describe "relay" do
          it "Named" do
          end

          it do
          end
        end
      RUBY

      expect { described_class.example_names(source) }.to raise_error(ArgumentError, /line 5\b/)
    end
  end
end
