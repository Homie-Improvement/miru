# frozen_string_literal: true

require "rails_helper"
require "yaml"

RSpec.describe "CI spec coverage in validations.yml" do
  it "does not cache the parallel runtime log from a cancelled or timed-out run" do
    workflow = YAML.safe_load_file(Rails.root.join(".github/workflows/validations.yml"))
    save_step = workflow.fetch("jobs").fetch("tests").fetch("steps").find do |step|
      step["name"] == "Save parallel runtime log cache"
    end

    # A timed-out job reports as cancelled and may leave a partial runtime log;
    # caching it makes the next run fall back to the file-size split.
    expect(save_step).not_to be_nil
    condition = save_step.fetch("if").to_s
    expect(condition).to include("!cancelled()")
    expect(condition).not_to include("always()")
    expect(condition).to include("hashFiles('tmp/parallel_runtime_rspec.log')")
  end
end

RSpec.describe "CI spec coverage in validations.yml" do
  it "runs the handoff specs exactly once, in a job that fails on a spec failure" do
    jobs = YAML.safe_load_file(Rails.root.join(".github/workflows/validations.yml")).fetch("jobs")
    handoff_dir = "spec/lib/timekeeping/handoff"

    parallel_step = jobs.fetch("tests").fetch("steps").find { |step| step["run"].to_s.include?("bin/parallel_test") }
    expect(parallel_step.fetch("run")).to include("--exclude-dir #{handoff_dir}")

    handoff_job = jobs.fetch("timekeeping-handoff")
    handoff_step = handoff_job.fetch("steps").find do |step|
      step["run"].to_s.include?("bundle exec rspec #{handoff_dir}")
    end
    expect(handoff_step).not_to be_nil
    expect(handoff_job.fetch("continue-on-error", false)).to be(false)
    expect(handoff_step.fetch("continue-on-error", false)).to be(false)
    expect(handoff_job["timeout-minutes"]).to be_a(Integer)

    serial_runs = jobs.flat_map { |_id, job| job.fetch("steps", []) }.count do |step|
      step["run"].to_s.match?(/rspec\s+#{Regexp.escape(handoff_dir)}/)
    end
    expect(serial_runs).to eq(1)
  end
end

RSpec.describe "CI spec coverage in validations.yml" do
  it "no longer runs the CLI request specs a second time outside the parallel step" do
    steps = YAML.safe_load_file(Rails.root.join(".github/workflows/validations.yml"))
      .fetch("jobs").fetch("tests").fetch("steps")

    serial_cli_runs = steps.select { |step| step["run"].to_s.include?("rspec spec/requests/api/v1/cli") }
    parallel_step = steps.find { |step| step["run"].to_s.include?("bin/parallel_test") }

    expect(serial_cli_runs).to be_empty
    # The parallel step must still cover the CLI specs: it may not exclude them.
    expect(parallel_step.fetch("run")).not_to include("spec/requests")
  end
end

RSpec.describe "CI spec coverage" do
  it "runs the handoff specs in their own job that fails the workflow, and excludes them from the parallel step" do
    workflow = YAML.safe_load_file(Rails.root.join(".github/workflows/validations.yml"))
    jobs = workflow.fetch("jobs")

    parallel_step = jobs.fetch("tests").fetch("steps").find { |step| step["run"].to_s.include?("bin/parallel_test") }
    expect(parallel_step).not_to be_nil
    expect(parallel_step.fetch("run")).to include("--exclude-dir spec/lib/timekeeping/handoff")

    handoff_job = jobs.fetch("timekeeping-handoff")
    expect(handoff_job["continue-on-error"]).to be_falsey
    handoff_steps = handoff_job.fetch("steps").select do |step|
      step["run"].to_s.include?("bundle exec rspec spec/lib/timekeeping/handoff")
    end
    expect(handoff_steps.size).to eq(1)
    expect(handoff_steps.first["continue-on-error"]).to be_falsey

    # Every other job's rspec steps leave the handoff directory alone, so it runs exactly once.
    other_runs = jobs.except("timekeeping-handoff").values.flat_map { |job| job.fetch("steps", []) }
      .map { |step| step["run"].to_s }
    expect(other_runs.grep(%r{rspec\s+spec/lib/timekeeping/handoff})).to be_empty
  end
end

RSpec.describe "CI spec coverage" do
  it "runs the CLI request specs once and skips caching the runtime log of a cancelled run" do
    workflow = YAML.safe_load_file(Rails.root.join(".github/workflows/validations.yml"))
    tests_steps = workflow.fetch("jobs").fetch("tests").fetch("steps")

    # The parallel step already covers spec/requests/api/v1/cli, so no separate serial step runs it again.
    expect(tests_steps.map { |step| step["run"].to_s }.grep(%r{rspec\s+spec/requests/api/v1/cli})).to be_empty
    parallel_run = tests_steps.find { |step| step["run"].to_s.include?("bin/parallel_test") }.fetch("run")
    expect(parallel_run).not_to include("spec/requests")

    save_step = tests_steps.find { |step| step["name"] == "Save parallel runtime log cache" }
    expect(save_step).not_to be_nil
    expect(save_step.fetch("if")).to include("!cancelled()")
    expect(save_step.fetch("if")).not_to include("always()")
  end
end

RSpec.describe "CI spec coverage across validations.yml jobs" do
  # The issue asks: "Make these checks pass: - `Running tests`". The fix moves work out of
  # the job instead of raising its limit, so the job must still finish inside 60 minutes.
  it "keeps Running tests at its one-hour limit and gives the moved handoff job a bounded limit of its own" do
    workflow = YAML.safe_load_file(Rails.root.join(".github/workflows/validations.yml"))
    jobs = workflow.fetch("jobs")

    tests_job = jobs.fetch("tests")
    expect(tests_job.fetch("name")).to eq("Running tests")
    expect(tests_job.fetch("timeout-minutes")).to eq(60)

    handoff_job = jobs.fetch("timekeeping-handoff")
    handoff_limit = handoff_job.fetch("timeout-minutes")
    expect(handoff_limit).to be_a(Integer)
    expect(handoff_limit).to be_between(1, 60)

    parallel_runs = tests_job.fetch("steps").filter_map { |step| step["run"] }.join("\n")
    expect(parallel_runs).not_to include("bundle exec rspec spec/requests/api/v1/cli")
  end
end

RSpec.describe "CI spec coverage" do
  # A directory excluded from the parallel step but run nowhere else, or run in a
  # job or step that ignores failures, would let a failing spec pass CI.
  it "runs every directory excluded from the parallel step in another job that fails on a spec failure" do
    workflow = YAML.safe_load_file(Rails.root.join(".github/workflows/validations.yml"), aliases: true)
    jobs = workflow.fetch("jobs")
    parallel_step = jobs.fetch("tests").fetch("steps").find { |step| step["run"].to_s.include?("bin/parallel_test") }
    excluded_dirs = parallel_step.fetch("run").scan(/--exclude-dir\s+(\S+)/).flatten

    expect(excluded_dirs).to include("spec/lib/timekeeping/handoff")
    expect(jobs.fetch("tests").fetch("steps").map { |step| step["run"].to_s })
      .not_to include(a_string_matching(%r{rspec spec/requests/api/v1/cli}))

    excluded_dirs.each do |dir|
      runners = jobs.reject { |name, _| name == "tests" }.flat_map do |name, job|
        Array(job["steps"]).filter_map do |step|
          [name, job, step] if step["run"].to_s.match?(/rspec\s+#{Regexp.escape(dir)}(\s|\z)/)
        end
      end

      expect(runners).not_to be_empty, "#{dir} is excluded from the parallel step but no other job runs it"
      runners.each do |name, job, step|
        expect(job["continue-on-error"]).to be_falsey, "job #{name} ignores failures of #{dir}"
        expect(step["continue-on-error"]).to be_falsey, "the step in #{name} ignores failures of #{dir}"
      end
    end
  end
end

RSpec.describe "CI spec coverage guard for directories moved out of the parallel step" do
  # Returns one message per directory excluded from the parallel step that no
  # other job runs with failures counted. Taking the parsed workflow lets the
  # failure cases below run against altered copies instead of the file on disk.
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

  let(:handoff_workflow) do
    YAML.safe_load_file(Rails.root.join(".github/workflows/validations.yml"), aliases: true)
  end
  let(:handoff_job) { handoff_workflow.fetch("jobs").fetch("timekeeping-handoff") }
  let(:handoff_rspec_step) do
    handoff_job.fetch("steps").find { |step| step["run"].to_s.include?("rspec spec/lib/timekeeping/handoff") }
  end

  it "finds every excluded directory covered in the real workflow" do
    expect(uncovered_excluded_dirs(handoff_workflow)).to be_empty
  end

  it "fails when the step that runs the handoff specs ignores failures" do
    handoff_rspec_step["continue-on-error"] = true

    expect(uncovered_excluded_dirs(handoff_workflow)).to eq(
      ["spec/lib/timekeeping/handoff is not run by any job that fails on a spec failure"]
    )
  end

  it "fails when the handoff job ignores failures" do
    handoff_job["continue-on-error"] = true

    expect(uncovered_excluded_dirs(handoff_workflow)).not_to be_empty
  end

  it "fails when the handoff job is removed" do
    handoff_workflow.fetch("jobs").delete("timekeeping-handoff")

    expect(uncovered_excluded_dirs(handoff_workflow)).not_to be_empty
  end

  it "fails when the handoff job runs a different directory" do
    handoff_rspec_step["run"] = "bundle exec rspec spec/lib/timekeeping/other"

    expect(uncovered_excluded_dirs(handoff_workflow)).not_to be_empty
  end
end
