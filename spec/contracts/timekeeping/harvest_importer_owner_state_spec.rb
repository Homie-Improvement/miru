# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Harvest importer spec ownership checks" do
  it "every Harvest importer example checks the ownership state before its first import and carries no owner_state metadata" do
    lines = Rails.root.join("spec/services/imports/harvest_time_entries_importer_spec.rb").read.lines
    import_call = /described_class\.new\(.*\)\.process|run_harvest_import\(/
    example_start = /\A\s*it "(.+?)"/

    # "no example in the file carries `owner_state:` metadata, so no regression example silently runs in a different ownership state from the one selected"
    expect(lines.grep(/\bowner_state:/)).to be_empty

    # "Each regression example calls `expect_owner_state!` right before the operation it proves."
    unchecked = []
    current = nil
    lines.each do |line|
      if (match = example_start.match(line))
        current = { name: match[1], checked: false, done: false }
      elsif current && !current[:done]
        if line.include?("expect_owner_state!")
          current[:checked] = true
        elsif line.match?(import_call)
          unchecked << current[:name] unless current[:checked]
          current[:done] = true
        end
      end
    end

    expect(unchecked).to eq([])
  end
end
