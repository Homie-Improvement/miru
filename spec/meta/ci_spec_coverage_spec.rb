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
      step["run"].to_s.match?(/rspec\s+#{Regexp.escape(handoff_dir)}(\s|\z)/)
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

  describe "guard for the handoff spec groups and their summary check" do
    let(:summary_check_name) { "Timekeeping handoff specs" }

    # Returns one message per way the handoff matrix could leave spec files unrun,
    # or the summary check could pass or be skipped while a group failed. Branch
    # protection reads only the summary check, so either gap would let a failing
    # handoff spec merge. Taking the parsed workflow lets the failure cases run
    # against altered copies.
    def handoff_group_problems(workflow)
      jobs = workflow.fetch("jobs")
      group_job = jobs.fetch("timekeeping-handoff")
      strategy = group_job.fetch("strategy", {})
      rspec_run = /rspec\s+#{Regexp.escape(handoff_dir)}(\s|\z)/
      run = group_job.fetch("steps").map { |step| step["run"].to_s }.find { |text| text.match?(rspec_run) }.to_s
      group_count = run[/\s-n\s+(\d+)/, 1].to_i
      groups = strategy.dig("matrix", "group")

      problems = []
      unless group_count.positive? && groups == (1..group_count).to_a
        problems << "matrix groups #{groups.inspect} do not list 1 to #{group_count}"
      end
      problems << "fail-fast is not off for the handoff groups" unless strategy["fail-fast"] == false

      summary_job = jobs.values.find { |job| job["name"] == summary_check_name }
      return problems << "no job is named #{summary_check_name}" unless summary_job

      unless Array(summary_job["needs"]).include?("timekeeping-handoff")
        problems << "#{summary_check_name} does not need timekeeping-handoff"
      end
      problems << "#{summary_check_name} is skipped when a group fails" unless summary_job["if"].to_s.include?("always()")
      problems
    end

    let(:summary_job) { jobs.values.find { |job| job["name"] == summary_check_name } }
    let(:summary_step) { summary_job.fetch("steps").sole }

    it "finds the real workflow's groups complete and its summary check wired to them" do
      expect(handoff_group_problems(workflow)).to be_empty
    end

    it "fails when a group is missing from the matrix" do
      handoff_job.fetch("strategy").fetch("matrix")["group"] = [1, 2]

      expect(handoff_group_problems(workflow)).to eq(["matrix groups [1, 2] do not list 1 to 3"])
    end

    it "fails when one failing group cancels the others" do
      handoff_job.fetch("strategy")["fail-fast"] = true

      expect(handoff_group_problems(workflow)).to eq(["fail-fast is not off for the handoff groups"])
    end

    it "fails when the summary check no longer needs the handoff groups" do
      summary_job.delete("needs")

      expect(handoff_group_problems(workflow)).to eq(["Timekeeping handoff specs does not need timekeeping-handoff"])
    end

    it "fails when the summary check would be skipped after a group fails" do
      summary_job["if"] = summary_job.fetch("if").sub("always() && ", "")

      expect(handoff_group_problems(workflow)).to eq(["Timekeeping handoff specs is skipped when a group fails"])
    end

    it "fails when no job carries the summary check's name" do
      summary_job["name"] = "Timekeeping handoff summary"

      expect(handoff_group_problems(workflow)).to eq(["no job is named Timekeeping handoff specs"])
    end

    it "passes the summary step only when every handoff group succeeded" do
      expect(summary_step.fetch("env").fetch("HANDOFF_RESULT")).to eq("${{ needs.timekeeping-handoff.result }}")

      outcomes = %w[success failure cancelled skipped].to_h do |result|
        passed = system({ "HANDOFF_RESULT" => result }, "bash", "-c", summary_step.fetch("run"),
                        out: File::NULL, err: File::NULL)
        [result, passed]
      end

      expect(outcomes).to eq("success" => true, "failure" => false, "cancelled" => false, "skipped" => false)
    end
  end
end
