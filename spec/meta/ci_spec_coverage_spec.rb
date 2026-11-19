# frozen_string_literal: true

require "rails_helper"
require "yaml"

RSpec.describe "CI spec coverage in validations.yml" do
  let(:workflow) { YAML.safe_load_file(Rails.root.join(".github/workflows/validations.yml"), aliases: true) }
  let(:jobs) { workflow.fetch("jobs") }
  let(:tests_job) { jobs.fetch("tests") }
  let(:tests_steps) { tests_job.fetch("steps") }
  let(:parallel_run) { tests_steps.find { |step| step["run"].to_s.include?("bin/parallel_test") }.fetch("run") }
  let(:handoff_dir) { "spec/lib/timekeeping/handoff" }
  let(:handoff_job) { jobs.fetch("timekeeping-handoff") }

  # The issue asks: "Make these checks pass: - `Running tests`". The fix moves work out of
  # the job instead of raising its limit, so the job must still finish inside 60 minutes.
  it "keeps Running tests at its one-hour limit and gives the moved handoff job a bounded limit of its own" do
    expect(tests_job.fetch("name")).to eq("Running tests")
    expect(tests_job.fetch("timeout-minutes")).to eq(60)

    handoff_limit = handoff_job.fetch("timeout-minutes")
    expect(handoff_limit).to be_a(Integer)
    expect(handoff_limit).to be_between(1, 60)
  end

  it "runs the handoff specs exactly once, in a job that fails on a spec failure" do
    expect(parallel_run).to include("--exclude-dir #{handoff_dir}")

    handoff_steps = handoff_job.fetch("steps").select do |step|
      step["run"].to_s.include?("bundle exec rspec #{handoff_dir}")
    end
    expect(handoff_steps.size).to eq(1)
    expect(handoff_job.fetch("continue-on-error", false)).to be(false)
    expect(handoff_steps.first.fetch("continue-on-error", false)).to be(false)

    all_runs = jobs.values.flat_map { |job| job.fetch("steps", []) }.map { |step| step["run"].to_s }
    expect(all_runs.grep(/rspec\s+#{Regexp.escape(handoff_dir)}/).size).to eq(1)
  end

  it "no longer runs the CLI request specs a second time outside the parallel step" do
    expect(tests_steps.map { |step| step["run"].to_s }.grep(%r{rspec\s+spec/requests/api/v1/cli})).to be_empty
    # The parallel step must still cover the CLI specs: it may not exclude them.
    expect(parallel_run).not_to include("spec/requests")
  end

  it "does not cache the parallel runtime log from a cancelled or timed-out run" do
    save_step = tests_steps.find { |step| step["name"] == "Save parallel runtime log cache" }

    # A timed-out job reports as cancelled and may leave a partial runtime log;
    # caching it makes the next run fall back to the file-size split.
    expect(save_step).not_to be_nil
    condition = save_step.fetch("if").to_s
    expect(condition).to include("!cancelled()")
    expect(condition).not_to include("always()")
    expect(condition).to include("hashFiles('tmp/parallel_runtime_rspec.log')")
  end

  describe "guard for directories moved out of the parallel step" do
    # Returns one message per directory excluded from the parallel step that no
    # other job runs with failures counted. A directory run nowhere else, or only
    # in a job or step that ignores failures, would let a failing spec pass CI.
    # Taking the parsed workflow lets the failure cases run against altered copies.
    def uncovered_excluded_dirs(workflow)
      jobs = workflow.fetch("jobs")
      parallel_step = jobs.fetch("tests").fetch("steps").find { |step| step["run"].to_s.include?("bin/parallel_test") }
      excluded_dirs = parallel_step.fetch("run").scan(/--exclude-dir\s+(\S+)/).flatten

      excluded_dirs.filter_map do |dir|
        rspec_run = /rspec\s+#{Regexp.escape(dir)}(\s|\z)/
        counted = jobs.except("tests").any? do |_name, job|
          !job["continue-on-error"] && Array(job["steps"]).any? do |step|
            step["run"].to_s.match?(rspec_run) && !step["continue-on-error"]
          end
        end
        "#{dir} is not run by any job that fails on a spec failure" unless counted
      end
    end

    let(:handoff_rspec_step) do
      handoff_job.fetch("steps").find { |step| step["run"].to_s.include?("rspec #{handoff_dir}") }
    end

    it "finds every excluded directory covered in the real workflow" do
      expect(parallel_run.scan(/--exclude-dir\s+(\S+)/).flatten).to include(handoff_dir)
      expect(uncovered_excluded_dirs(workflow)).to be_empty
    end

    it "fails when the step that runs the handoff specs ignores failures" do
      handoff_rspec_step["continue-on-error"] = true

      expect(uncovered_excluded_dirs(workflow)).to eq(
        ["spec/lib/timekeeping/handoff is not run by any job that fails on a spec failure"]
      )
    end

    it "fails when the handoff job ignores failures" do
      handoff_job["continue-on-error"] = true

      expect(uncovered_excluded_dirs(workflow)).not_to be_empty
    end

    it "fails when the handoff job is removed" do
      jobs.delete("timekeeping-handoff")

      expect(uncovered_excluded_dirs(workflow)).not_to be_empty
    end

    it "fails when the handoff job runs a different directory" do
      handoff_rspec_step["run"] = "bundle exec rspec spec/lib/timekeeping/other"

      expect(uncovered_excluded_dirs(workflow)).not_to be_empty
    end
  end
end
