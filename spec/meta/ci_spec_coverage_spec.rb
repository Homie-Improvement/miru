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
      # A hard-coded or missing group selector makes the legs repeat one group or
      # every file, so some files run more than once and others never.
      unless run.scan(/--only-group\b/).size == 1 && run.match?(/--only-group\s+\$\{\{\s*matrix\.group\s*\}\}(\s|\z)/)
        problems << "the handoff run does not select its group with --only-group ${{ matrix.group }}"
      end

      summary_job = jobs.values.find { |job| job["name"] == summary_check_name }
      return problems << "no job is named #{summary_check_name}" unless summary_job

      unless Array(summary_job["needs"]).include?("timekeeping-handoff")
        problems << "#{summary_check_name} does not need timekeeping-handoff"
      end
      problems << "#{summary_check_name} is skipped when a group fails" unless summary_job["if"].to_s.include?("always()")
      # Either key would let the check conclude as passed after its step failed or was skipped.
      summary_parts = [summary_job, *Array(summary_job["steps"])]
      if summary_parts.any? { |part| part["continue-on-error"] } || Array(summary_job["steps"]).any? { |step| step.key?("if") }
        problems << "#{summary_check_name} can pass without its step failing on a failed group"
      end
      problems
    end

    let(:summary_job) { jobs.values.find { |job| job["name"] == summary_check_name } }
    let(:summary_step) { summary_job.fetch("steps").sole }
    let(:handoff_job_run_step) do
      handoff_job.fetch("steps").find { |step| step["run"].to_s.include?("rspec #{handoff_dir}") }
    end

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

    it "fails when every leg runs the same hard-coded group" do
      handoff_job_run_step["run"] = handoff_job_run_step.fetch("run").sub("${{ matrix.group }}", "1")

      expect(handoff_group_problems(workflow)).to eq(
        ["the handoff run does not select its group with --only-group ${{ matrix.group }}"]
      )
    end

    it "fails when the handoff run selects no group" do
      handoff_job_run_step["run"] = handoff_job_run_step.fetch("run").sub(" --only-group ${{ matrix.group }}", "")

      expect(handoff_group_problems(workflow)).to eq(
        ["the handoff run does not select its group with --only-group ${{ matrix.group }}"]
      )
    end

    it "fails when the summary step ignores its own failure" do
      summary_step["continue-on-error"] = true

      expect(handoff_group_problems(workflow)).to eq(
        ["Timekeeping handoff specs can pass without its step failing on a failed group"]
      )
    end

    it "fails when the summary job ignores its own failure" do
      summary_job["continue-on-error"] = true

      expect(handoff_group_problems(workflow)).to eq(
        ["Timekeeping handoff specs can pass without its step failing on a failed group"]
      )
    end

    it "fails when the summary step can be skipped" do
      summary_step["if"] = false

      expect(handoff_group_problems(workflow)).to eq(
        ["Timekeeping handoff specs can pass without its step failing on a failed group"]
      )
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

  # The handoff live spec skips itself unless TIMEKEEPING_LIVE is "1", so a job that
  # names it with the wrong env, a skipped condition or ignored failures still goes green.
  describe "guard for the live handoff job" do
    let(:live_handoff_spec) { "spec/integration/timekeeping/handoff_live_spec.rb" }
    let(:live_handoff_jobs) do
      jobs.values.select { |job| Array(job["steps"]).any? { |step| runs_live_handoff?(step) } }
    end
    let(:live_handoff_step) { live_handoff_jobs.first.fetch("steps").find { |step| runs_live_handoff?(step) } }

    def runs_live_handoff?(step)
      step["run"].to_s.include?(live_handoff_spec)
    end

    # The handoff spec refuses, and its after hook would otherwise empty, any database
    # the shared guard does not accept, so the meta spec asks that same guard.
    def test_database_url?(url)
      return false if url.to_s.empty?

      TestDatabaseGuard.require_test_database_url!(url)
      true
    rescue TestDatabaseGuard::NotATestDatabase
      false
    end

    def live_handoff_job_problems(name, job)
      step = job.fetch("steps").find { |candidate| runs_live_handoff?(candidate) }
      # A step's env overrides the job's, and the rspec process sees the merged values.
      env = (job["env"] || {}).merge(step["env"] || {})
      {
        "does not set TIMEKEEPING_LIVE to \"1\"" => env["TIMEKEEPING_LIVE"] != "1",
        "does not name a _test database in TIMEKEEPING_DATABASE_URL" => !test_database_url?(env["TIMEKEEPING_DATABASE_URL"]),
        "ignores failures" => job["continue-on-error"] || step["continue-on-error"],
        # Any condition, even one that looks harmless, can skip the proof on some push.
        "runs only under a condition" => job.key?("if") || step.key?("if")
      }.select { |_problem, present| present }.keys.map { |problem| "#{name} #{problem}" }
    end

    # Returns no messages when at least one job runs the handoff live spec for real on
    # every push; otherwise one message per way each candidate job falls short.
    # Taking the parsed workflow lets the failure cases run against altered copies.
    def live_handoff_problems(workflow)
      candidates = workflow.fetch("jobs").select do |_name, job|
        Array(job["steps"]).any? { |step| runs_live_handoff?(step) }
      end
      return ["no job runs #{live_handoff_spec}"] if candidates.empty?

      problems = candidates.map { |name, job| live_handoff_job_problems(name, job) }
      problems.any?(&:empty?) ? [] : problems.flatten
    end

    it "finds a live handoff job in the real workflow" do
      # "A CI job in .github/workflows/validations.yml sets TIMEKEEPING_LIVE=1 and TIMEKEEPING_DATABASE_URL
      # and runs spec/integration/timekeeping/handoff_live_spec.rb on every push."
      expect(live_handoff_problems(workflow)).to be_empty
    end

    it "fails when the live job leaves TIMEKEEPING_LIVE unset" do
      live_handoff_jobs.each { |job| job.fetch("env").delete("TIMEKEEPING_LIVE") }

      expect(live_handoff_problems(workflow)).not_to be_empty
    end

    it "fails when the live job sets TIMEKEEPING_LIVE to anything but \"1\"" do
      live_handoff_jobs.each { |job| job.fetch("env")["TIMEKEEPING_LIVE"] = "0" }

      expect(live_handoff_problems(workflow)).not_to be_empty
    end

    it "fails when the live job sets no TIMEKEEPING_DATABASE_URL" do
      live_handoff_jobs.each { |job| job.fetch("env").delete("TIMEKEEPING_DATABASE_URL") }

      expect(live_handoff_problems(workflow)).not_to be_empty
    end

    it "fails when TIMEKEEPING_DATABASE_URL names a database without the _test suffix" do
      live_handoff_jobs.each do |job|
        env = job.fetch("env")
        env["TIMEKEEPING_DATABASE_URL"] = env.fetch("TIMEKEEPING_DATABASE_URL").sub(%r{/[^/?]+\z}, "/timekeeping_live")
      end

      expect(live_handoff_problems(workflow)).not_to be_empty
    end

    it "fails when TIMEKEEPING_DATABASE_URL overrides its database with a dbname query" do
      live_handoff_jobs.each do |job|
        env = job.fetch("env")
        env["TIMEKEEPING_DATABASE_URL"] = "#{env.fetch('TIMEKEEPING_DATABASE_URL')}?dbname=timekeeping"
      end

      expect(live_handoff_problems(workflow)).not_to be_empty
    end

    it "fails when no run step names the live handoff spec" do
      live_handoff_step["run"] = live_handoff_step.fetch("run").sub(live_handoff_spec, "").strip

      expect(live_handoff_problems(workflow)).to eq(["no job runs #{live_handoff_spec}"])
    end

    it "fails when the live job ignores failures" do
      live_handoff_jobs.each { |job| job["continue-on-error"] = true }

      expect(live_handoff_problems(workflow)).not_to be_empty
    end

    it "fails when the live handoff step ignores failures" do
      live_handoff_step["continue-on-error"] = true

      expect(live_handoff_problems(workflow)).not_to be_empty
    end

    it "fails when the live job skips pushes whose message mentions skip ci" do
      # A push titled "Fix skip ci handling" would skip the proof.
      live_handoff_jobs.each do |job|
        job["if"] = "github.event_name != 'push' || !contains(github.event.head_commit.message, 'skip ci')"
      end

      expect(live_handoff_problems(workflow)).not_to be_empty
    end

    it "fails when the live handoff step runs only for pull requests" do
      live_handoff_step["if"] = "github.event_name == 'pull_request'"

      expect(live_handoff_problems(workflow)).not_to be_empty
    end

    it "fails when the live job is disabled with if: false" do
      live_handoff_jobs.each { |job| job["if"] = false }

      expect(live_handoff_problems(workflow)).not_to be_empty
    end

    it "fails when the live handoff step is disabled with if: false" do
      live_handoff_step["if"] = false

      expect(live_handoff_problems(workflow)).not_to be_empty
    end

    it "fails when the live handoff step overrides TIMEKEEPING_LIVE to \"0\"" do
      live_handoff_step["env"] = { "TIMEKEEPING_LIVE" => "0" }

      expect(live_handoff_problems(workflow)).not_to be_empty
    end

    it "fails when the live handoff step overrides TIMEKEEPING_DATABASE_URL with a non-test database" do
      job_url = live_handoff_jobs.first.fetch("env").fetch("TIMEKEEPING_DATABASE_URL")
      live_handoff_step["env"] = { "TIMEKEEPING_DATABASE_URL" => job_url.sub(%r{/[^/?]+\z}, "/timekeeping_live") }

      expect(live_handoff_problems(workflow)).not_to be_empty
    end

    it "names the live handoff spec in exactly one job, which still runs the live alerts spec" do
      # Two jobs naming it would boot the live server and reload the seed twice per push.
      expect(live_handoff_jobs.size).to eq(1)
      expect(live_handoff_step.fetch("run")).to match(%r{rspec\b.*spec/integration/timekeeping/alerts_live_spec\.rb})
    end

    it "gives the live handoff job a read-only token and no secrets" do
      # The job runs code from any pushed branch.
      live_handoff_jobs.each do |job|
        expect(job.fetch("permissions")).to eq("contents" => "read")
        expect(job.to_yaml).not_to include("secrets.")
      end
    end

    # The live job runs only when the workflow starts, so a narrowed push trigger skips the
    # proof on some branches, and a cancelling concurrency group shared by push and
    # pull_request runs lets one kind of run cancel the other's proof mid-run.
    describe "guard for the live handoff trigger" do
      # The event keeps a push and a pull request of one branch apart; the branch keeps two
      # pushes of one branch together, so a newer push still cancels the older run. Only this
      # exact group is accepted: an expression that merely mentions github.event_name can
      # still resolve to the same value for both events.
      let(:event_separated_group) do
        "${{ github.workflow }}-${{ github.event_name }}-${{ github.head_ref || github.ref_name }}"
      end
      let(:base_group) { "${{ github.workflow }}-${{ github.head_ref || github.ref_name }}" }
      # Psych reads the bare workflow key `on` as the boolean true.
      let(:triggers) { workflow.fetch(true) { workflow.fetch("on") } }
      let(:push_trigger) { triggers["push"] ||= {} }

      def push_trigger_problems(triggers)
        # `on: push` and `on: [push]` name the trigger without any filter.
        trigger_map = triggers.is_a?(Hash) ? triggers : Array(triggers).index_with(nil)
        return ["the workflow does not run on push"] unless trigger_map.key?("push")

        push = trigger_map.fetch("push") || {}
        {
          "push lists branches other than \"**\"" => push.key?("branches") && push.fetch("branches") != ["**"],
          "push skips branches through branches-ignore" => push.key?("branches-ignore"),
          "push runs only when some paths change" => push.key?("paths"),
          "push skips changes through paths-ignore" => push.key?("paths-ignore"),
          "push runs only for tags" => push.key?("tags") && !push.key?("branches")
        }.select { |_problem, present| present }.keys
      end

      # These triggers run branch code with the base repository's token and secrets, which the
      # live job must never get now that it runs code from any pushed branch.
      def privileged_trigger_problems(triggers)
        names = triggers.is_a?(Hash) ? triggers.keys : Array(triggers)
        (names & %w[pull_request_target workflow_run]).map do |name|
          "the workflow runs on #{name}, which gives branch code the base repository's privileges"
        end
      end

      # Returns the group settings when they can cancel a run, or nil when they never do.
      def cancelling_settings(concurrency)
        return nil if concurrency.nil?

        settings = concurrency.is_a?(Hash) ? concurrency : { "group" => concurrency }
        # Anything but an explicit false may cancel, including an expression.
        settings.fetch("cancel-in-progress", false) == false ? nil : settings
      end

      def concurrency_problems(scope, concurrency)
        settings = cancelling_settings(concurrency)
        return [] if settings.nil?

        squash = ->(text) { text.to_s.gsub(/\s+/, "") }
        return [] if squash.call(settings["group"]) == squash.call(event_separated_group)

        ["#{scope} cancels runs in a group other than one per event and branch"]
      end

      def live_jobs_in(workflow)
        workflow.fetch("jobs").select { |_name, job| Array(job["steps"]).any? { |step| runs_live_handoff?(step) } }
      end

      # Returns no messages when a push to any branch starts the workflow, no trigger gives branch
      # code base privileges, and no cancelling concurrency group lets push and pull_request runs
      # of one branch cancel each other.
      def live_handoff_trigger_problems(workflow)
        workflow_triggers = workflow.fetch(true) { workflow.fetch("on") }

        push_trigger_problems(workflow_triggers) +
          privileged_trigger_problems(workflow_triggers) +
          concurrency_problems("the workflow", workflow["concurrency"]) +
          live_jobs_in(workflow).flat_map { |name, job| concurrency_problems(name, job["concurrency"]) }
      end

      it "finds no trigger or concurrency problem in the real workflow" do
        expect(live_handoff_trigger_problems(workflow)).to be_empty
        # A newer push to one branch still cancels the older push run of that branch.
        expect(workflow.fetch("concurrency").fetch("cancel-in-progress")).to be(true)
        # Branch protection may require this check by job name, so the proof stays in this job.
        expect(live_jobs_in(workflow).keys).to eq(["timekeeping-alerts-live"])
      end

      it "fails when the workflow gains a trigger that runs branch code with base privileges" do
        triggers["pull_request_target"] = { "branches" => ["main"] }
        triggers["workflow_run"] = { "workflows" => ["CI Test Suite"] }

        expect(live_handoff_trigger_problems(workflow)).to include(
          "the workflow runs on pull_request_target, which gives branch code the base repository's privileges",
          "the workflow runs on workflow_run, which gives branch code the base repository's privileges"
        )
      end

      it "fails when push lists branches as a single star, which does not match slash-named branches such as feature/x" do
        push_trigger["branches"] = ["*"]

        expect(live_handoff_trigger_problems(workflow)).to include("push lists branches other than \"**\"")
      end

      # A group keyed on the commit or the run is unique per push, so a newer push to a branch
      # would no longer cancel the older run.
      it "fails when the cancelling group is keyed on github.sha or github.run_id" do
        %w[github.sha github.run_id].each do |per_run_field|
          workflow["concurrency"] = { "group" => "#{event_separated_group}-${{ #{per_run_field} }}", "cancel-in-progress" => true }

          expect(live_handoff_trigger_problems(workflow)).to include(
            "the workflow cancels runs in a group other than one per event and branch"
          )
        end
      end

      it "fails when the group puts github.event_name inside an expression that merges both events" do
        workflow["concurrency"] = {
          "group" => "${{ github.workflow }}-${{ github.event_name == 'push' && github.ref_name || github.head_ref }}",
          "cancel-in-progress" => true
        }

        expect(live_handoff_trigger_problems(workflow)).to include(
          "the workflow cancels runs in a group other than one per event and branch"
        )
      end

      it "fails when the cancelling group goes back to branch only" do
        workflow["concurrency"] = { "group" => base_group, "cancel-in-progress" => true }

        expect(live_handoff_trigger_problems(workflow)).not_to be_empty
      end

      it "accepts a branch-only group that never cancels" do
        workflow["concurrency"] = { "group" => base_group, "cancel-in-progress" => false }

        expect(concurrency_problems("the workflow", workflow["concurrency"])).to be_empty
      end

      it "fails when the live job adds a cancelling branch-only group of its own" do
        live_handoff_jobs.each { |job| job["concurrency"] = { "group" => base_group, "cancel-in-progress" => true } }

        expect(live_handoff_trigger_problems(workflow)).to include(
          "timekeeping-alerts-live cancels runs in a group other than one per event and branch"
        )
      end

      it "fails when push goes back to the release branch list" do
        push_trigger["branches"] = %w[develop main stable-3-0 production]

        expect(live_handoff_trigger_problems(workflow)).to include("push lists branches other than \"**\"")
      end

      it "fails when push skips branches through branches-ignore" do
        push_trigger["branches-ignore"] = ["dependabot/**"]

        expect(live_handoff_trigger_problems(workflow)).to include("push skips branches through branches-ignore")
      end

      it "fails when push runs only when some paths change" do
        push_trigger["paths"] = ["app/**"]

        expect(live_handoff_trigger_problems(workflow)).to include("push runs only when some paths change")
      end

      it "fails when push skips changes through paths-ignore" do
        push_trigger["paths-ignore"] = ["docs/**"]

        expect(live_handoff_trigger_problems(workflow)).to include("push skips changes through paths-ignore")
      end

      it "fails when the workflow no longer runs on push" do
        triggers.delete("push")

        expect(live_handoff_trigger_problems(workflow)).to include("the workflow does not run on push")
      end

      it "fails when push runs only for tags" do
        triggers["push"] = { "tags" => ["v*"] }

        expect(live_handoff_trigger_problems(workflow)).to include("push runs only for tags")
      end

      it "accepts a push trigger with no filter at all" do
        triggers["push"] = nil

        expect(push_trigger_problems(triggers)).to be_empty
      end
    end
  end

  context "more tests 10" do
    it "keeps the security audit running on every branch push while the test jobs skip feature-branch pushes" do
      # The audit checks dependencies against newly published advisories, so a
      # condition on it would let a feature-branch push skip that check.
      security_audit = jobs.fetch("security-audit")
      expect(security_audit).not_to have_key("if")
      expect(Array(security_audit["steps"]).none? { |step| step.key?("if") }).to be(true)
      expect(security_audit.fetch("permissions")).to eq("contents" => "read")

      # "Either the jobs other than timekeeping-alerts-live (such as `tests` and the handoff matrix)
      # skip feature-branch pushes through one condition that reads a single branch list kept in one
      # place, or a recorded decision says they keep running on every branch push."
      shared_condition = tests_job.fetch("if")
      expect(shared_condition).to eq(
        "github.event_name != 'push' || " \
        "(contains(fromJSON('[\"develop\",\"main\",\"stable-3-0\",\"production\"]'), github.ref_name) && " \
        "!contains(github.event.head_commit.message, 'skip ci'))"
      )
      expect(handoff_job.fetch("if")).to eq(shared_condition)
    end
  end

  context "more tests 11" do
    it "skips feature-branch pushes in every test job through one shared condition that lists the release branches" do
      # Acceptance: "Either the jobs other than timekeeping-alerts-live (such as `tests` and the handoff matrix)
      # skip feature-branch pushes through one condition that reads a single branch list kept in one place, or a
      # recorded decision says they keep running on every branch push."
      # The whole expression is compared, so swapping its inner && for || (which would run every job on a
      # feature-branch push) fails here.
      expected_condition = "github.event_name != 'push' || " \
                           "(contains(fromJSON('[\"develop\",\"main\",\"stable-3-0\",\"production\"]'), github.ref_name) && " \
                           "!contains(github.event.head_commit.message, 'skip ci'))"
      shared_jobs = %w[
        tests timekeeping-handoff responsive-system-specs timekeeping-rules
        timekeeping-relay timekeeping timekeeping-runtime-live
      ]

      shared_jobs.each do |job_id|
        expect(jobs.fetch(job_id).fetch("if").to_s.strip).to eq(expected_condition), "#{job_id} does not read the shared condition"
      end
    end
  end

  context "more tests 12" do
    it "runs the handoff summary check exactly when the handoff matrix ran, under always()" do
      # The summary step runs `test "$HANDOFF_RESULT" = success`. If it ran while the matrix was skipped on a
      # feature-branch push, it would fail every such push; deriving its skip from the matrix result keeps the
      # two in step without repeating the branch list.
      summary_job = jobs.fetch("timekeeping-handoff-result")

      expect(summary_job.fetch("if").to_s.strip).to eq("always() && needs.timekeeping-handoff.result != 'skipped'")
      expect(summary_job.fetch("if").to_s).not_to include("stable-3-0")
    end
  end

  context "more tests 13" do
    it "keeps the live proof and the security audit unconditioned and gives every other job a branch-aware condition" do
      # The live proof runs on every branch push; the security audit keeps running on every push by a recorded
      # decision. Every other job must read the release branch list, so a new job added without it fails here.
      unconditioned = %w[timekeeping-alerts-live security-audit]

      unconditioned.each do |job_id|
        expect(jobs.fetch(job_id)).not_to have_key("if"), "#{job_id} gained a condition"
      end

      branch_aware = jobs.except(*unconditioned).reject do |_job_id, job|
        job["if"].to_s.include?("fromJSON('[\"develop\",\"main\",\"stable-3-0\",\"production\"]')") ||
          job["if"].to_s.include?("needs.timekeeping-handoff.result != 'skipped'")
      end
      expect(branch_aware.keys).to be_empty
    end
  end

  context "more tests 14" do
    it "writes the release branch list once in validations.yml and reuses it by alias" do
      # Acceptance: "...skip feature-branch pushes through one condition that reads a single branch list kept in
      # one place..." The parsed YAML resolves aliases into equal strings, so only the raw text shows whether the
      # list was written once or copied.
      raw_text = File.read(Rails.root.join(".github/workflows/validations.yml"))
      branch_list = "fromJSON('[\"develop\",\"main\",\"stable-3-0\",\"production\"]')"

      expect(raw_text.scan(branch_list).size).to eq(1)
      expect(raw_text.scan("&full_suite_condition").size).to eq(1)
      expect(raw_text.scan("*full_suite_condition").size).to eq(6)
      expect(raw_text).not_to include("!contains(github.event.head_commit.message, 'skip ci'))\n    if:")
    end
  end

  context "more tests 15" do
    it "runs the suite jobs on feature-branch pushes only through the one shared release-branch condition" do
      # "Either the jobs other than timekeeping-alerts-live (such as `tests` and the handoff matrix) skip
      # feature-branch pushes through one condition that reads a single branch list kept in one place, or a
      # recorded decision says they keep running on every branch push."
      expected_condition =
        "github.event_name != 'push' || " \
        "(contains(fromJSON('[\"develop\",\"main\",\"stable-3-0\",\"production\"]'), github.ref_name) && " \
        "!contains(github.event.head_commit.message, 'skip ci'))"
      shared_jobs = %w[
        tests timekeeping-handoff responsive-system-specs timekeeping-rules
        timekeeping-relay timekeeping timekeeping-runtime-live
      ]

      shared_jobs.each do |job_id|
        expect(jobs.fetch(job_id)["if"].to_s.strip).to eq(expected_condition), "#{job_id} does not read the shared condition"
      end
    end
  end

  context "more tests 16" do
    it "skips the handoff summary check exactly when the handoff matrix was skipped" do
      summary = jobs.fetch("timekeeping-handoff-result")

      # A summary that ran while the matrix skipped would compare "skipped" with "success" and fail every
      # feature-branch push, so it must follow the matrix result and never repeat the branch list.
      expect(summary["if"].to_s.strip).to eq("always() && needs.timekeeping-handoff.result != 'skipped'")
      expect(summary["if"].to_s).not_to include("fromJSON")
      expect(summary["if"].to_s).not_to include("skip ci")
    end
  end

  context "more tests 17" do
    it "gives every workflow job either the shared condition, the derived summary condition or no condition at all" do
      shared_condition = jobs.fetch("tests")["if"].to_s.strip
      expect(shared_condition).to include("fromJSON")

      unconditioned = %w[timekeeping-alerts-live security-audit]
      unconditioned.each do |job_id|
        expect(jobs.fetch(job_id)).not_to have_key("if"), "#{job_id} must keep running on every branch push"
      end

      jobs.except(*unconditioned, "timekeeping-handoff-result").each do |job_id, job|
        expect(job["if"].to_s.strip).to eq(shared_condition), "#{job_id} does not read the shared condition"
      end
      # YAML 1.1 reads the bare key `on` as true.
      expect(workflow.fetch(true) { workflow.fetch("on") }.dig("push", "branches")).to eq(["**"])
    end
  end

  context "more tests 18" do
    it "keeps the release branch list and the shared condition anchor written once in validations.yml" do
      raw = File.read(Rails.root.join(".github/workflows/validations.yml"))

      # "through one condition that reads a single branch list kept in one place"
      expect(raw.scan(%q{fromJSON('["develop","main","stable-3-0","production"]')}).size).to eq(1)
      expect(raw.scan("&full_suite_condition").size).to eq(1)
      expect(raw.scan("*full_suite_condition").size).to eq(6)
      expect(raw).not_to include("!contains(github.event.head_commit.message, 'skip ci')\n    if:")
      expect(raw.scan("'skip ci'").size).to eq(1)
    end
  end

  context "more tests 19" do
    # Acceptance: "Either the jobs other than timekeeping-alerts-live (such as `tests` and the handoff
    # matrix) skip feature-branch pushes through one condition that reads a single branch list kept
    # in one place, or a recorded decision says they keep running on every branch push."
    it "records beside security-audit why it keeps running on every branch push" do
      raw_lines = File.read(Rails.root.join(".github/workflows/validations.yml")).lines
      job_line = raw_lines.index { |line| line.match?(/\A  security-audit:\s*\z/) }
      expect(job_line).not_to be_nil

      comment_block = raw_lines[0...job_line].reverse.take_while { |line| line.match?(/\A\s*#/) }.reverse.join
      expect(comment_block).not_to be_empty
      expect(comment_block).to match(/every (branch )?push/i)

      expect(jobs.fetch("security-audit")).not_to have_key("if")
    end
  end

  context "more tests 20" do
    # Acceptance: "Either the jobs other than timekeeping-alerts-live (such as `tests` and the handoff matrix)
    # skip feature-branch pushes through one condition that reads a single branch list kept in one place, or a
    # recorded decision says they keep running on every branch push."
    # Comparing the whole expression, not its fragments, rejects a swap of the inner && for ||, which would run
    # every job on a push to a feature branch such as feature/example.
    it "skips every test job on a feature-branch push through the exact shared release-branch condition, not an operator-swapped one" do
      expected_condition = "github.event_name != 'push' || " \
                           "(contains(fromJSON('[\"develop\",\"main\",\"stable-3-0\",\"production\"]'), github.ref_name) " \
                           "&& !contains(github.event.head_commit.message, 'skip ci'))"
      shared_jobs = %w[
        tests timekeeping-handoff responsive-system-specs timekeeping-rules
        timekeeping-relay timekeeping timekeeping-runtime-live
      ]

      conditions = shared_jobs.index_with { |id| jobs.fetch(id)["if"].to_s.strip }

      expect(conditions).to eq(shared_jobs.index_with(expected_condition))
    end
  end

  context "more tests 21" do
    # Acceptance: "Either the jobs other than timekeeping-alerts-live (such as `tests` and the handoff matrix)
    # skip feature-branch pushes through one condition that reads a single branch list kept in one place, or a
    # recorded decision says they keep running on every branch push."
    # The summary runs under always(). If it kept its own copy of the old skip ci text while the matrix skipped a
    # feature branch, it would compare a skipped result against success and fail every feature-branch push.
    it "skips the handoff summary check exactly when the handoff matrix is skipped, so a feature-branch push leaves no failed summary" do
      summary_condition = jobs.fetch("timekeeping-handoff-result")["if"].to_s.strip

      expect(summary_condition).to eq("always() && needs.timekeeping-handoff.result != 'skipped'")
      expect(summary_condition).not_to include("skip ci")
      expect(summary_condition).not_to include("fromJSON")
    end
  end

  context "more tests 22" do
    # Acceptance: "Either the jobs other than timekeeping-alerts-live (such as `tests` and the handoff matrix)
    # skip feature-branch pushes through one condition that reads a single branch list kept in one place, or a
    # recorded decision says they keep running on every branch push."
    # The security audit takes the recorded keep-running arm; the live proof must run on every branch push.
    # Either job picking up the shared condition would let a feature branch or a skip ci message skip it.
    it "leaves the live proof and the security audit with no condition so a skip ci message or a feature branch cannot skip them" do
      unconditioned = %w[timekeeping-alerts-live security-audit].index_with { |id| jobs.fetch(id).key?("if") }

      expect(unconditioned).to eq("timekeeping-alerts-live" => false, "security-audit" => false)
      expect(jobs.fetch("tests")["if"].to_s).to include("fromJSON")
    end
  end

  context "more tests 23" do
    # Acceptance: "Either the jobs other than timekeeping-alerts-live (such as `tests` and the handoff matrix)
    # skip feature-branch pushes through one condition that reads a single branch list kept in one place, or a
    # recorded decision says they keep running on every branch push."
    # Parsing resolves aliases into equal strings, so only the raw text shows whether the list was copied into
    # each job, where a later edit to one copy would leave the jobs disagreeing.
    it "keeps the release branch list and its shared condition in one place in the workflow text instead of a copy per job" do
      raw_text = File.read(Rails.root.join(".github/workflows/validations.yml"))

      expect(raw_text.scan("fromJSON(").size).to eq(1)
      expect(raw_text.scan("&full_suite_condition").size).to eq(1)
      expect(raw_text.scan("*full_suite_condition").size).to eq(6)
      expect(raw_text.scan("contains(github.event.head_commit.message, 'skip ci')").size).to eq(1)
    end
  end
end
