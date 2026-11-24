# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require Rails.root.join("script/ci/timekeeping_live_specs.rb").to_s

RSpec.describe TimekeepingLiveSpecs do
  let(:release_branches) { %w[develop main stable-3-0 production] }
  let(:live) do
    %w[
      spec/integration/timekeeping/alerts_live_spec.rb
      spec/integration/timekeeping/handoff_live_spec.rb
      spec/integration/timekeeping/invoice_first_save_live_spec.rb
      spec/integration/timekeeping/live_instance_generation_spec.rb
    ]
  end
  let(:pull_request_env) do
    { "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_REF_NAME" => "507/merge", "GITHUB_BASE_REF" => "main" }
  end
  let(:main_push_env) { { "GITHUB_EVENT_NAME" => "push", "GITHUB_REF_NAME" => "main", "GITHUB_BASE_REF" => "" } }

  # Runs the selector with git and rspec replaced by the given diff and a recorder.
  # Returns the exit status, what it printed to stdout and stderr, and each list rspec received.
  def run_timekeeping_live_selector(env:, changed_paths:, live_specs: live)
    out = StringIO.new
    err = StringIO.new
    rspec_calls = []
    status = described_class.run(
      env:, out:, err:, live_specs:, full_run_branches: release_branches, changed_paths:,
      run_rspec: ->(specs) { rspec_calls << specs; 0 }
    )
    [status, out.string, err.string, rspec_calls]
  end

  it "selection never passes a changed path to rspec unless it is an on-disk live spec" do
    live_specs = %w[
      spec/integration/timekeeping/alerts_live_spec.rb
      spec/integration/timekeeping/handoff_live_spec.rb
    ]
    # File names come from the pull request's own diff, so they are untrusted.
    hostile_paths = [
      "spec/integration/timekeeping/x; touch pwned_live_spec.rb",
      "spec/integration/timekeeping/../../../config/initializers/evil_live_spec.rb",
      "spec/integration/timekeeping_other/x_live_spec.rb",
      "spec/integration/timekeeping/local_relay_spec.rb",
      "spec/integration/timekeeping/deleted_live_spec.rb"
    ]

    expect(described_class.selection(changed_paths: hostile_paths, live_specs:)).to eq([])
    expect(
      described_class.selection(
        changed_paths: hostile_paths + ["spec/integration/timekeeping/handoff_live_spec.rb"], live_specs:
      )
    ).to eq(["spec/integration/timekeeping/handoff_live_spec.rb"])
  end

  # "When the selection is empty, the job still reports success with a line that says no live spec was selected,
  # so a required check never hangs" - a git failure is not an empty selection, so it must not take that green path.
  it "fails the live step instead of reporting an empty selection when the pull request diff cannot be read" do
    failing_diff = ->(_base) { raise TimekeepingLiveSpecs::GitError, "fatal: bad revision 'origin/main...HEAD'" }

    status, out, err, rspec_calls = run_timekeeping_live_selector(env: pull_request_env, changed_paths: failing_diff)

    expect(status).not_to eq(0)
    expect(rspec_calls).to be_empty
    expect(out + err).not_to match(/no live timekeeping spec was selected/i)
    expect(err).to include("bad revision")
  end

  it "run hands rspec only the selected live spec paths as separate entries, dropping untrusted names from the diff" do
    diff = lambda do |_base|
      [
        "spec/integration/timekeeping/alerts_live_spec.rb",
        "spec/integration/timekeeping/$(touch pwned)_live_spec.rb",
        "README.md"
      ]
    end

    status, _out, _err, rspec_calls = run_timekeeping_live_selector(env: pull_request_env, changed_paths: diff)

    expect(status).to eq(0)
    expect(rspec_calls).to eq([["spec/integration/timekeeping/alerts_live_spec.rb"]])
  end

  it "on a pull request that edits one live spec, runs rspec once with only that spec" do
    # "On a pull request, the live job runs only the live specs under `spec/integration/timekeeping` that the
    # change adds or edits, plus the live specs that load a support file under `spec/support/timekeeping` the
    # change edits"
    bases = []
    diff = lambda do |base|
      bases << base
      ["spec/integration/timekeeping/handoff_live_spec.rb", "app/models/user.rb"]
    end

    _status, _out, _err, rspec_calls = run_timekeeping_live_selector(env: pull_request_env, changed_paths: diff)

    expect(bases).to eq(["origin/main"])
    expect(rspec_calls).to eq([["spec/integration/timekeeping/handoff_live_spec.rb"]])
  end

  it "with an empty selection, exits 0 with a no live spec line and never calls rspec" do
    # "When the selection is empty, the job still reports success with a line that says no live spec was
    # selected, so a required check never hangs"
    diff = ->(_base) { ["app/models/user.rb", "spec/integration/timekeeping/local_relay_spec.rb"] }

    status, out, _err, rspec_calls = run_timekeeping_live_selector(env: pull_request_env, changed_paths: diff)

    expect(status).to eq(0)
    expect(out).to match(/no live Timekeeping spec was selected/i)
    # rspec with no file arguments would run the whole suite, so it must not be called at all.
    expect(rspec_calls).to be_empty
  end

  it "on a push to main, runs the full live set without computing a diff" do
    # "On a push to main, the job runs the full `spec/integration/timekeeping` live set, as today"
    diff_calls = []

    _status, _out, _err, rspec_calls = run_timekeeping_live_selector(
      env: main_push_env, changed_paths: ->(base) { diff_calls << base; [] }
    )

    expect(diff_calls).to be_empty
    expect(rspec_calls).to eq([live])
  end

  it "reports the no-spec line and succeeds on a push to main when no live spec exists on disk" do
    status, out, _err, rspec_calls = run_timekeeping_live_selector(
      env: main_push_env, live_specs: [],
      changed_paths: ->(_base) { raise "a push to main must not compute a diff" }
    )

    expect(status).to eq(0)
    expect(out).to include("No live Timekeeping spec was selected for this change.")
    expect(rspec_calls).to be_empty
  end

  it "selects the full live set for each named full-set path and nothing for near-miss paths" do
    # "A pull request that changes `lib/timekeeping`, `timekeeping/`, `app/services/timekeeping`, `db/`, the live
    # support files or the workflow itself runs the full `spec/integration/timekeeping` live set"
    full_set_paths = %w[
      lib/timekeeping/handoff.rb
      timekeeping/Gemfile
      timekeeping/Gemfile.lock
      app/services/timekeeping/relay.rb
      db/schema.rb
      spec/support/timekeeping/live_instance.rb
      .github/workflows/validations.yml
      script/ci/timekeeping_live_specs.rb
    ]
    # Each shares a prefix with a trigger but not its directory boundary.
    near_misses = %w[
      lib/timekeeping_demo/x.rb
      dbx/x.rb
      db_tools/x.rb
      spec/lib/timekeeping/x.rb
      app/services/timekeeping_extra/x.rb
      spec/support/timekeeping_other/x.rb
      spec/integration/timekeeping_other/x_live_spec.rb
      spec/integration/timekeeping/local_relay_spec.rb
      .github/workflows/validations.yml.bak
      app/models/user.rb
    ]

    full_set_paths.each do |path|
      expect(described_class.full_set_trigger?(path)).to be(true), path
      expect(described_class.selection(changed_paths: [path], live_specs: live)).to eq(live), path
    end
    near_misses.each do |path|
      expect(described_class.full_set_trigger?(path)).to be(false), path
      expect(described_class.selection(changed_paths: [path], live_specs: live)).to eq([]), path
    end
  end

  it "on a pull request that changes a full-set path beside one live spec, runs the full live set" do
    # "A pull request that changes `lib/timekeeping`, `timekeeping/`, `app/services/timekeeping`, `db/`,
    # the live support files or the workflow itself runs the full `spec/integration/timekeeping` live set"
    _status, _out, _err, rspec_calls = run_timekeeping_live_selector(
      env: pull_request_env,
      changed_paths: ->(_base) { ["spec/integration/timekeeping/alerts_live_spec.rb", "db/schema.rb"] }
    )

    expect(rspec_calls).to eq([live])
  end

  it "selects an added live spec and a renamed one by its new path, and never a deleted one" do
    # live_specs holds only files on disk, so a deleted or renamed-away path is absent from it.
    on_disk = %w[
      spec/integration/timekeeping/alerts_live_spec.rb
      spec/integration/timekeeping/billing_live_spec.rb
      spec/integration/timekeeping/handoff_renamed_live_spec.rb
    ]
    changed = %w[
      spec/integration/timekeeping/handoff_renamed_live_spec.rb
      spec/integration/timekeeping/handoff_live_spec.rb
      spec/integration/timekeeping/billing_live_spec.rb
      spec/integration/timekeeping/removed_live_spec.rb
    ]

    expect(described_class.selection(changed_paths: changed, live_specs: on_disk)).to eq(
      %w[
        spec/integration/timekeeping/billing_live_spec.rb
        spec/integration/timekeeping/handoff_renamed_live_spec.rb
      ]
    )
  end

  it "chooses a full run for release-branch pushes and manual runs, and a diff base for pull requests and feature pushes" do
    base = lambda do |event, ref, base_ref = ""|
      described_class.comparison_base(event_name: event, ref_name: ref, base_ref:, full_run_branches: release_branches)
    end

    expect(base.call("push", "main")).to be_nil
    expect(base.call("push", "develop")).to be_nil
    expect(base.call("push", "production")).to be_nil
    expect(base.call("workflow_dispatch", "feature/x")).to be_nil
    expect(base.call("push", "feature/x")).to eq("origin/main")
    expect(base.call("pull_request", "42/merge", "stable-3-0")).to eq("origin/stable-3-0")
    # Without a base branch the change's own files cannot be known.
    expect { base.call("pull_request", "42/merge", "") }.to raise_error(ArgumentError)
    expect { base.call("pull_request", "42/merge", nil) }.to raise_error(ArgumentError)
  end

  it "finds exactly the four gated live specs and the interrupted-handoff spec in the real spec/integration/timekeeping directory" do
    # owned_entries_spec.rb and regression_adapter_spec.rb also need TIMEKEEPING_REGRESSION=1, and
    # local_relay_spec.rb has no live gate, so none of them belongs in the live set.
    # interrupted_handoff_spec.rb is gated by the :integrated_runtime tag and named by the selector.
    expect(described_class.live_specs(root: Rails.root.to_s))
      .to eq((live + ["spec/integration/timekeeping/interrupted_handoff_spec.rb"]).sort)
  end

  it "a diff touching the live support files runs all five live specs, the interrupted-handoff spec included" do
    real_live_specs = described_class.live_specs(root: Rails.root.to_s)

    status, _out, err, rspec_calls = run_timekeeping_live_selector(
      env: pull_request_env, changed_paths: ->(_base) { ["spec/support/timekeeping/queue_ledger.rb"] },
      live_specs: real_live_specs
    )

    expect(status).to eq(0), err
    expect(rspec_calls).to eq([real_live_specs])
    expect(real_live_specs.size).to eq(5)
    expect(real_live_specs).to include("spec/integration/timekeeping/interrupted_handoff_spec.rb")
  end

  it "recognises a single-quoted gate, and fails the run on a TIMEKEEPING_LIVE gate it cannot recognise" do
    Dir.mktmpdir do |root|
      dir = File.join(root, "spec/integration/timekeeping")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "quoted_live_spec.rb"), "skip unless ENV['TIMEKEEPING_LIVE'] == '1'\n")
      File.write(File.join(dir, "plain_spec.rb"), "it { expect(1).to eq(1) }\n")

      expect(described_class.live_specs(root:)).to eq(["spec/integration/timekeeping/quoted_live_spec.rb"])

      File.write(File.join(dir, "fetch_live_spec.rb"), "skip unless ENV.fetch(\"TIMEKEEPING_LIVE\", nil) == \"1\"\n")

      expect { described_class.live_specs(root:) }
        .to raise_error(TimekeepingLiveSpecs::ConfigError, /fetch_live_spec\.rb/)

      # Leaving the spec out would let the required check pass with it unrun.
      out = StringIO.new
      err = StringIO.new
      rspec_calls = []
      status = Dir.chdir(root) do
        described_class.run(
          env: main_push_env, out:, err:, full_run_branches: release_branches,
          changed_paths: ->(_base) { [] }, run_rspec: ->(specs) { rspec_calls << specs; 0 }
        )
      end

      expect(status).to eq(1)
      expect(err.string).to include("fetch_live_spec.rb")
      expect(out.string).not_to include("No live Timekeeping spec was selected")
      expect(rspec_calls).to be_empty
    end
  end

  it "reads the release branches from the workflow's pull_request trigger" do
    workflow_path = Rails.root.join(".github/workflows/validations.yml").to_s

    expect(described_class.full_run_branches(workflow_path:))
      .to contain_exactly("develop", "main", "stable-3-0", "production")
  end

  it "counts a spec as live only when it gates on TIMEKEEPING_LIVE and needs no TIMEKEEPING_REGRESSION" do
    live_source = <<~'RUBY'
      before(:all) do
        skip "Set TIMEKEEPING_LIVE=1 to boot a real Timekeeping server" unless ENV["TIMEKEEPING_LIVE"] == "1"
      end
    RUBY
    regression_source = <<~'RUBY'
      unless ENV["TIMEKEEPING_REGRESSION"] == "1" && ENV["TIMEKEEPING_LIVE"] == "1"
        skip "Set TIMEKEEPING_REGRESSION=1 and TIMEKEEPING_LIVE=1 to run against the live Timekeeping app"
      end
    RUBY
    ungated_source = <<~'RUBY'
      it "relays through WebMock" do
        expect(true).to be(true)
      end
    RUBY

    expect(described_class.live_spec?(live_source)).to be(true)
    expect(described_class.live_spec?(regression_source)).to be(false)
    expect(described_class.live_spec?(ungated_source)).to be(false)
    expect(described_class.live_spec?("")).to be(false)
    # Naming the regression flag in a comment does not make a spec need it.
    expect(described_class.live_spec?("#{live_source}# Unlike TIMEKEEPING_REGRESSION proofs, this needs only one flag.\n"))
      .to be(true)
  end

  # Inherited GIT_* variables (GIT_DIR, GIT_WORK_TREE and the like, exported by a git hook)
  # override chdir:, so fixture git commands would otherwise act on the developer's checkout.
  def without_inherited_git_variables_for_live_selector
    saved = ENV.to_h.select { |key, _value| key.start_with?("GIT_") }
    saved.each_key { |key| ENV.delete(key) }
    yield
  ensure
    ENV.update(saved)
  end

  it "lists only the files the branch adds, edits or deletes since its merge base, not commits main gained later" do
    Dir.mktmpdir do |tmp|
      unset_git_variables = ENV.keys.grep(/\AGIT_/).index_with(nil)
      git = lambda do |dir, *args|
        output, status = Open3.capture2e(
          unset_git_variables,
          "git", "-c", "user.name=Spec", "-c", "user.email=spec@example.com",
          "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false", *args, chdir: dir
        )
        raise "git #{args.join(' ')} failed: #{output}" unless status.success?

        output
      end
      write = lambda do |dir, path, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
        File.write(File.join(dir, path), text)
      end

      origin = File.join(tmp, "origin")
      FileUtils.mkdir_p(origin)
      git.call(origin, "init", "-q")
      write.call(origin, "spec/integration/timekeeping/alerts_live_spec.rb", "one\n")
      write.call(origin, "spec/integration/timekeeping/handoff_live_spec.rb", "one\n")
      git.call(origin, "add", "-A")
      git.call(origin, "commit", "-q", "--no-verify", "-m", "base")

      clone = File.join(tmp, "clone")
      git.call(tmp, "clone", "-q", origin, clone)
      git.call(clone, "checkout", "-q", "-b", "feature")
      write.call(clone, "spec/integration/timekeeping/alerts_live_spec.rb", "two\n")
      write.call(clone, "spec/integration/timekeeping/new_live_spec.rb", "new\n")
      git.call(clone, "rm", "-q", "spec/integration/timekeeping/handoff_live_spec.rb")
      git.call(clone, "add", "-A")
      git.call(clone, "commit", "-q", "--no-verify", "-m", "feature")

      # main moves on after the branch was cut; its commit is not part of the change.
      write.call(origin, "app/models/later_on_main.rb", "later\n")
      git.call(origin, "add", "-A")
      git.call(origin, "commit", "-q", "--no-verify", "-m", "later on main")

      paths = without_inherited_git_variables_for_live_selector do
        Dir.chdir(clone) { described_class.changed_paths("origin/main") }
      end

      expected_paths = %w[
        spec/integration/timekeeping/alerts_live_spec.rb
        spec/integration/timekeeping/handoff_live_spec.rb
        spec/integration/timekeeping/new_live_spec.rb
      ]
      expect(paths.sort).to eq(expected_paths)

      # CI checks out one commit with no base branch; changed_paths must fetch the history it needs.
      git.call(clone, "push", "-q", "--no-verify", "origin", "feature")
      shallow = File.join(tmp, "shallow")
      git.call(tmp, "clone", "-q", "--depth", "1", "--branch", "feature", "file://#{origin}", shallow)
      expect(git.call(shallow, "rev-parse", "--is-shallow-repository").strip).to eq("true")

      shallow_paths = without_inherited_git_variables_for_live_selector do
        Dir.chdir(shallow) { described_class.changed_paths("origin/main") }
      end

      expect(shallow_paths.sort).to eq(expected_paths)
    end
  end

  it "exits with rspec's own failing status after handing it the full live set as separate arguments" do
    Dir.mktmpdir do |fake_bin|
      args_file = File.join(fake_bin, "args")
      fake_bundle = File.join(fake_bin, "bundle")
      File.write(fake_bundle, "#!/bin/sh\nfor arg in \"$@\"; do echo \"$arg\"; done > #{args_file}\nexit 3\n")
      File.chmod(0o755, fake_bundle)
      run_env = {
        "PATH" => [fake_bin, File.dirname(RbConfig.ruby), ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "GITHUB_EVENT_NAME" => "push", "GITHUB_REF_NAME" => "main", "GITHUB_BASE_REF" => ""
      }

      _output, status = Open3.capture2e(run_env, RbConfig.ruby, "script/ci/timekeeping_live_specs.rb",
                                        chdir: Rails.root.to_s)

      # A failing live spec must turn the required check red.
      expect(status.exitstatus).to eq(3)
      full_live_set = (live + ["spec/integration/timekeeping/interrupted_handoff_spec.rb"]).sort
      expect(File.readlines(args_file, chomp: true)).to eq(["exec", "rspec", *full_live_set])
    end
  end

  # An empty list here would read as "no live spec touched" and pass the required check with nothing run.
  it "raises a git error for a base branch that does not exist rather than returning no changed paths" do
    Dir.chdir(Rails.root) do
      expect { described_class.changed_paths("origin/timekeeping-live-specs-no-such-branch") }
        .to raise_error(TimekeepingLiveSpecs::GitError)
    end
  end

  # "No non-dedicated queue job runs during these suites, shown by the teardown queue ledger"
  # The ledger's teardown verdict only runs on the interrupted-handoff suites if the live job selects them.
  context "the interrupted-handoff spec" do
    it "a pull request that edits only the interrupted-handoff spec runs exactly that file in the live job" do
      interrupted = "spec/integration/timekeeping/interrupted_handoff_spec.rb"
      env = { "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_REF_NAME" => "597/merge", "GITHUB_BASE_REF" => "main" }
      out = StringIO.new
      err = StringIO.new
      rspec_calls = []

      status = Dir.chdir(Rails.root.to_s) do
        described_class.run(
          env:, out:, err:, full_run_branches: %w[develop main stable-3-0 production],
          changed_paths: ->(_base) { [interrupted] }, run_rspec: ->(specs) { rspec_calls << specs; 0 }
        )
      end

      expect(status).to eq(0), err.string
      expect(rspec_calls).to eq([[interrupted]])
      expect(out.string).not_to include("No live Timekeeping spec was selected")
    end

    # The sibling integrated suite stays out, because selecting every integrated suite is separate work.
    it "a pull request that edits the interrupted handoff spec and a sibling integrated suite runs only the interrupted handoff spec live" do
      changed = %w[
        spec/integration/timekeeping/money_guard_spec.rb
        spec/integration/timekeeping/interrupted_handoff_spec.rb
      ]

      status, _out, err, rspec_calls = run_timekeeping_live_selector(
        env: pull_request_env, changed_paths: ->(_base) { changed },
        live_specs: described_class.live_specs(root: Rails.root.to_s)
      )

      expect(status).to eq(0), err
      expect(rspec_calls).to eq([["spec/integration/timekeeping/interrupted_handoff_spec.rb"]])
    end

    # A deleted or renamed file must not be handed to rspec, and the integrated-runtime tag alone selects nothing.
    it "live_specs lists the interrupted handoff spec only while it exists and never a differently named integrated suite" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "spec/integration/timekeeping")
        FileUtils.mkdir_p(dir)
        tagged_source = <<~RUBY
          RSpec.describe "tagged", :integrated_runtime, committed_data: true do
            it { expect(1).to eq(1) }
          end
        RUBY
        File.write(File.join(dir, "sibling_integrated_spec.rb"), tagged_source)

        expect(described_class.live_specs(root:)).to eq([])

        File.write(File.join(dir, "interrupted_handoff_spec.rb"), tagged_source)

        expect(described_class.live_specs(root:)).to eq(["spec/integration/timekeeping/interrupted_handoff_spec.rb"])
      end
    end
  end
end
