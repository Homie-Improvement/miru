# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe TimekeepingDemo::CLI do
  it "an unknown verb exits 64 without starting any process or writing a versions file" do
    Dir.mktmpdir do |state_dir|
      # Any call on this double raises, so the test fails if the CLI starts anything.
      supervisor = double("supervisor")

      status = nil
      expect do
        status = described_class.run(["bogus"], root: Rails.root.to_s, supervisor:, state_dir:)
      end.to output.to_stdout_from_any_process.or output.to_stderr_from_any_process

      expect(status).to eq(64)
      expect(Dir.children(state_dir)).to be_empty
    end
  end
end
