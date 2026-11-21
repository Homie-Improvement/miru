# frozen_string_literal: true

require "open3"
require "yaml"

# Chooses which live Timekeeping specs the "Timekeeping alerts against a live
# service" CI job runs, then runs them.
#
# Release-branch pushes and manual runs get the full live set. Pull requests
# and feature-branch pushes get only the live specs their diff adds or edits,
# or the full set when the diff touches code every live spec depends on.
#
# Run from the repository root: ruby script/ci/timekeeping_live_specs.rb
module TimekeepingLiveSpecs
  # Raised when git cannot fetch the base or list the changed files. The job
  # must fail then: an empty list would read as "no live spec touched".
  class GitError < StandardError; end

  # Raised when the workflow's release-branch list cannot be read.
  class ConfigError < StandardError; end

  LIVE_SPEC_GLOB = "spec/integration/timekeeping/*_spec.rb"
  LIVE_FLAG = "TIMEKEEPING_LIVE"
  # Matches ENV["TIMEKEEPING_LIVE"] == "1" in either quote style and any spacing.
  LIVE_GATE = /ENV\[\s*(["'])TIMEKEEPING_LIVE\1\s*\]\s*==\s*(["'])1\2/
  # Specs that also need this flag skip their live examples in this job.
  REGRESSION_FLAG = "TIMEKEEPING_REGRESSION"

  # Each prefix ends in "/" so "lib/timekeeping/" never matches "lib/timekeeping_demo/".
  FULL_SET_PREFIXES = %w[
    lib/timekeeping/
    timekeeping/
    app/services/timekeeping/
    db/
    spec/support/timekeeping/
  ].freeze
  # The selector runs as part of the workflow, so editing it is editing the workflow.
  FULL_SET_FILES = %w[
    .github/workflows/validations.yml
    script/ci/timekeeping_live_specs.rb
  ].freeze

  WORKFLOW_PATH = ".github/workflows/validations.yml"
  DEFAULT_BRANCH = "main"
  NO_SPEC_MESSAGE = "No live Timekeeping spec was selected for this change."

  module_function

  # Returns the ref to diff against, or nil when the run takes the full live set
  # without looking at a diff.
  def comparison_base(event_name:, ref_name:, base_ref:, full_run_branches:)
    case event_name
    when "pull_request"
      raise ArgumentError, "a pull_request run needs GITHUB_BASE_REF" if base_ref.to_s.strip.empty?

      "origin/#{base_ref}"
    when "push"
      # A push event does not say which branch a feature branch was cut from, so it
      # diffs against main. A branch cut from another release branch can then pick
      # up that branch's own commits and run more live specs than it needs, never fewer.
      full_run_branches.include?(ref_name) ? nil : "origin/#{DEFAULT_BRANCH}"
    end
  end

  # Every live spec loads every support file (spec/rails_helper.rb requires all of
  # spec/support), so a support edit selects the full set like the other triggers.
  def selection(changed_paths:, live_specs:)
    return live_specs if changed_paths.any? { |path| full_set_trigger?(path) }

    (changed_paths & live_specs).sort
  end

  def full_set_trigger?(path)
    FULL_SET_FILES.include?(path) || path.start_with?(*FULL_SET_PREFIXES)
  end

  def live_spec?(source)
    source.match?(LIVE_GATE) && !source.include?(REGRESSION_FLAG)
  end

  # A spec that reads TIMEKEEPING_LIVE through a gate this script does not recognise
  # raises ConfigError: leaving it out would let the check pass with that spec unrun.
  def live_specs(root: Dir.pwd)
    Dir.glob(LIVE_SPEC_GLOB, base: root).sort.select do |path|
      source = File.read(File.join(root, path))
      next true if live_spec?(source)
      next false unless source.include?(LIVE_FLAG) && !source.include?(REGRESSION_FLAG)

      raise ConfigError, "#{path} reads #{LIVE_FLAG} without the gate #{LIVE_GATE.source}"
    end
  end

  # The pull_request branches are the release branches: their pushes run the full set.
  def full_run_branches(workflow_path: WORKFLOW_PATH)
    workflow = YAML.safe_load_file(workflow_path, aliases: true)
    # YAML 1.1 reads the bare key `on` as true.
    triggers = workflow.fetch(true) { workflow["on"] }
    branches = triggers.is_a?(Hash) ? Array(triggers.dig("pull_request", "branches")) : []
    unless branches.include?(DEFAULT_BRANCH)
      raise ConfigError, "#{workflow_path} lists no pull_request branches that include #{DEFAULT_BRANCH}"
    end

    branches
  end

  # Fetches the base branch, deepening a shallow checkout so the merge base exists,
  # then lists the files changed since that merge base.
  def changed_paths(base)
    branch = base.delete_prefix("origin/")
    fetch = ["git", "fetch", "--no-tags", "--quiet"]
    fetch << "--unshallow" if git!("rev-parse", "--is-shallow-repository").strip == "true"
    run_git!(*fetch, "origin", "+refs/heads/#{branch}:refs/remotes/origin/#{branch}")
    git!("diff", "--name-only", "--no-renames", "-z", "#{base}...HEAD").split("\0")
  end

  def git!(*args)
    run_git!("git", *args)
  end

  def run_git!(*command)
    output, status = Open3.capture2e(*command)
    raise GitError, "#{command.join(' ')} failed: #{output}" unless status.success?

    output
  end

  # Returns the exit status for the job. run_rspec receives a non-empty list.
  # The live specs and release branches are read here rather than as argument
  # defaults so that a ConfigError while reading them reaches the rescue below.
  def run(env:, out: $stdout, err: $stderr, live_specs: nil,
          full_run_branches: nil, changed_paths: method(:changed_paths), run_rspec: method(:exec_rspec))
    live_specs ||= self.live_specs
    base = comparison_base(
      event_name: env["GITHUB_EVENT_NAME"], ref_name: env["GITHUB_REF_NAME"], base_ref: env["GITHUB_BASE_REF"],
      full_run_branches: full_run_branches || self.full_run_branches
    )
    specs = base.nil? ? live_specs : selection(changed_paths: changed_paths.call(base), live_specs:)
    # rspec with no file arguments would run the whole suite.
    if specs.empty?
      out.puts NO_SPEC_MESSAGE
      return 0
    end

    out.puts "Running live Timekeeping specs:", specs.map { |spec| "  #{spec}" }
    run_rspec.call(specs)
  rescue GitError, ConfigError, ArgumentError => e
    err.puts "Cannot choose live Timekeeping specs: #{e.message}"
    1
  end

  # Replaces this process so the step's exit status is rspec's own.
  def exec_rspec(specs)
    $stdout.flush
    exec("bundle", "exec", "rspec", *specs)
  end
end

exit(TimekeepingLiveSpecs.run(env: ENV)) if $PROGRAM_NAME == __FILE__
