# frozen_string_literal: true

require "rails_helper"
require "json"
require "open3"

# Outside the example transaction: the child rspec truncates this same test
# database in its before(:suite), and an open transaction holding the
# ownership row lock would make that truncation wait on this example forever.
RSpec.describe "IntegratedRuntime live examples without TIMEKEEPING_LIVE", :without_transaction do
  # "Live tests skip unless `TIMEKEEPING_LIVE=1`. They live in spec/lib/timekeeping_demo."
  it "the live harness examples report skipped and never fail when TIMEKEEPING_LIVE is unset" do
    live_spec = Rails.root.join("spec/lib/timekeeping_demo/integrated_runtime_live_spec.rb").to_s
    expect(File.exist?(live_spec)).to be(true)

    output, = Bundler.with_unbundled_env do
      Open3.capture2({ "TIMEKEEPING_LIVE" => nil, "RAILS_ENV" => "test" },
                     "bundle", "exec", "rspec", live_spec, "--format", "json", chdir: Rails.root.to_s)
    end
    summary = JSON.parse(output[output.index("{")..]).fetch("summary")

    expect(summary.fetch("example_count")).to be > 0
    expect(summary.fetch("failure_count")).to eq(0)
    expect(summary.fetch("pending_count")).to eq(summary.fetch("example_count"))
  end
end
