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

        ["#{scope} cancels runs in a group that push and pull_request runs of one branch can share"]
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

      it "matches the slash-named branch feature/x with every push branch pattern the workflow lists" do
        # GitHub branch filters treat `*` as any run of characters except `/` and `**` as any run at
        # all, so a `*` pattern would silently leave feature/x without the live proof.
        glob_to_regexp = lambda do |pattern|
          source = pattern.split(/(\*\*|\*)/).map do |part|
            case part
            when "**" then ".*"
            when "*" then "[^/]*"
            else Regexp.escape(part)
            end
          end.join
          Regexp.new("\\A#{source}\\z")
        end

        branches = Array((push_trigger || {}).fetch("branches", ["**"]))
        expect(branches.any? { |pattern| glob_to_regexp.call(pattern.to_s).match?("feature/x") }).to be(true)
        expect(glob_to_regexp.call("*").match?("feature/x")).to be(false)
      end

      it "puts a push and a pull request run of feature/x in different cancelling groups while two pushes still share one" do
        # Resolves the group the way GitHub does for the only expression shapes the workflow should
        # use: `github.<field>` lookups joined by `||`, where an empty value falls through to the
        # next one. Any other expression is refused, so an unexpected group cannot pass by accident.
        resolve_group = lambda do |template, context|
          template.to_s.gsub(/\$\{\{(.*?)\}\}/) do
            operands = Regexp.last_match(1).split("||").map(&:strip)
            unless operands.all? { |operand| operand.match?(/\Agithub\.[a-z_]+\z/) }
              raise ArgumentError, "unsupported concurrency expression: #{Regexp.last_match(0)}"
            end

            operands.map { |operand| context.fetch(operand.delete_prefix("github.")) }.find { |value| !value.empty? }.to_s
          end
        end

        push_context = {
          "workflow" => workflow.fetch("name"), "event_name" => "push", "ref_name" => "feature/x", "head_ref" => "",
          "sha" => "1111111", "run_id" => "101"
        }
        # A later push to the same branch differs only in its commit and run.
        newer_push_context = push_context.merge("sha" => "2222222", "run_id" => "102")
        pull_request_context = {
          "workflow" => workflow.fetch("name"), "event_name" => "pull_request", "ref_name" => "12/merge",
          "head_ref" => "feature/x", "sha" => "3333333", "run_id" => "103"
        }

        groups = [workflow["concurrency"], *live_jobs_in(workflow).values.pluck("concurrency")]
        groups.filter_map { |concurrency| cancelling_settings(concurrency) }.each do |settings|
          group = settings.fetch("group")
          expect(resolve_group.call(group, push_context)).not_to eq(resolve_group.call(group, pull_request_context))
          expect(resolve_group.call(group, push_context)).to eq(resolve_group.call(group, newer_push_context))
        end
      end

      it "fails when the group puts github.event_name inside an expression that merges both events" do
        workflow["concurrency"] = {
          "group" => "${{ github.workflow }}-${{ github.event_name == 'push' && github.ref_name || github.head_ref }}",
          "cancel-in-progress" => true
        }

        expect(live_handoff_trigger_problems(workflow)).to include(
          "the workflow cancels runs in a group that push and pull_request runs of one branch can share"
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
          "timekeeping-alerts-live cancels runs in a group that push and pull_request runs of one branch can share"
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
end
