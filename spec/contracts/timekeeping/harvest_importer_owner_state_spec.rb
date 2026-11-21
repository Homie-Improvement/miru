# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Harvest importer spec ownership checks" do
  # The titles of the examples in lines whose first import is not preceded by
  # an ownership check, or whose check is followed by a state change before it.
  def harvest_owner_state_unchecked_examples(lines)
    import_call = /described_class\.new\(.*\)\.process|run_harvest_import\(/
    example_start = /\A\s*it "(.+?)"/
    # A state applied after the check means the check no longer proves the state the import runs in.
    ownership_change = /TimekeepingOwnerState\.apply!/

    unchecked = []
    current = nil
    lines.each do |line|
      if (match = example_start.match(line))
        current = { name: match[1], checked: false, done: false }
      elsif current && !current[:done]
        if line.include?("expect_owner_state!")
          current[:checked] = true
        elsif line.match?(ownership_change)
          current[:checked] = false
        elsif line.match?(import_call)
          unchecked << current[:name] unless current[:checked]
          current[:done] = true
        end
      end
    end
    unchecked
  end

  it "every Harvest importer example checks the ownership state before its first import and carries no owner_state metadata" do
    lines = Rails.root.join("spec/services/imports/harvest_time_entries_importer_spec.rb").read.lines

    # "no example in the file carries `owner_state:` metadata, so no regression example silently runs in a different ownership state from the one selected"
    expect(lines.grep(/\bowner_state:/)).to be_empty

    # "Each regression example calls `expect_owner_state!` right before the operation it proves."
    expect(harvest_owner_state_unchecked_examples(lines)).to eq([])
  end

  it "flags an example that changes the ownership state between its check and its import" do
    lines = <<~RUBY.lines
      it "imports in the wrong state" do
        expect_owner_state!
        TimekeepingOwnerState.apply!("rollback")
        described_class.new(data_import).process
      end
      it "imports in the checked state" do
        TimekeepingOwnerState.apply!("rollback")
        expect_owner_state!
        run_harvest_import(data_import)
      end
    RUBY

    expect(harvest_owner_state_unchecked_examples(lines)).to eq(["imports in the wrong state"])
  end
end
