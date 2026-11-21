# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "open3"
require "stringio"
require "tmpdir"
require Rails.root.join("script/ci/timekeeping_live_specs.rb").to_s

RSpec.describe "script/ci/timekeeping_live_specs.rb" do
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

    expect(TimekeepingLiveSpecs.selection(changed_paths: hostile_paths, live_specs: live_specs)).to eq([])
    expect(
      TimekeepingLiveSpecs.selection(
        changed_paths: hostile_paths + ["spec/integration/timekeeping/handoff_live_spec.rb"],
        live_specs: live_specs
      )
    ).to eq(["spec/integration/timekeeping/handoff_live_spec.rb"])
  end
end

RSpec.describe "script/ci/timekeeping_live_specs.rb" do
  it "full_set_trigger? matches the issue's paths only on a directory boundary" do
    # "A pull request that changes `lib/timekeeping`, `timekeeping/`, `app/services/timekeeping`, `db/`, the live
    # support files or the workflow itself runs the full `spec/integration/timekeeping` live set"
    triggers = %w[
      lib/timekeeping/handoff.rb
      timekeeping/Gemfile.lock
      app/services/timekeeping/relay.rb
      db/schema.rb
      spec/support/timekeeping/live_instance.rb
      .github/workflows/validations.yml
    ]
    near_misses = %w[
      lib/timekeeping_demo/x.rb
      dbx/x.rb
      db_tools/x.rb
      spec/lib/timekeeping/x.rb
      app/services/timekeeping_extra/x.rb
      spec/support/timekeeping_other/x.rb
      .github/workflows/validations.yml.bak
    ]

    expect(triggers.reject { |path| TimekeepingLiveSpecs.full_set_trigger?(path) }).to eq([])
    expect(near_misses.select { |path| TimekeepingLiveSpecs.full_set_trigger?(path) }).to eq([])
  end
end

RSpec.describe "script/ci/timekeeping_live_specs.rb" do
  it "run fails the job when git cannot list the changed files instead of reporting no live spec selected" do
    out = StringIO.new
    err = StringIO.new
    rspec_calls = []

    status = TimekeepingLiveSpecs.run(
      env: { "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_BASE_REF" => "main", "GITHUB_REF_NAME" => "12/merge" },
      out: out,
      err: err,
      live_specs: %w[spec/integration/timekeeping/alerts_live_spec.rb spec/integration/timekeeping/handoff_live_spec.rb],
      full_run_branches: %w[develop main stable-3-0 production],
      changed_paths: ->(_base) { raise TimekeepingLiveSpecs::GitError, "fatal: bad revision 'origin/main...HEAD'" },
      run_rspec: ->(specs) { rspec_calls << specs; 0 }
    )

    # A broken lookup must not pass the required live check with nothing run.
    expect(status).not_to eq(0)
    expect(out.string + err.string).not_to match(/no live timekeeping spec was selected/i)
    expect(err.string).not_to be_empty
    expect(rspec_calls).to eq([])
  end
end

RSpec.describe "script/ci/timekeeping_live_specs.rb" do
  it "run hands rspec only the selected live spec paths as separate entries, dropping untrusted names from the diff" do
    rspec_calls = []
    live_specs = %w[spec/integration/timekeeping/alerts_live_spec.rb spec/integration/timekeeping/handoff_live_spec.rb]

    status = TimekeepingLiveSpecs.run(
      env: { "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_BASE_REF" => "main", "GITHUB_REF_NAME" => "12/merge" },
      out: StringIO.new,
      err: StringIO.new,
      live_specs: live_specs,
      full_run_branches: %w[develop main stable-3-0 production],
      changed_paths: lambda do |_base|
        [
          "spec/integration/timekeeping/alerts_live_spec.rb",
          "spec/integration/timekeeping/$(touch pwned)_live_spec.rb",
          "README.md"
        ]
      end,
      run_rspec: ->(specs) { rspec_calls << specs; 0 }
    )

    expect(status).to eq(0)
    expect(rspec_calls).to eq([["spec/integration/timekeeping/alerts_live_spec.rb"]])
  end
end

RSpec.describe "TimekeepingLiveSpecs" do
  it "on a pull request that edits one live spec, runs rspec once with only that spec" do
    # "On a pull request, the live job runs only the live specs under `spec/integration/timekeeping` that the
    # change adds or edits, plus the live specs that load a support file under `spec/support/timekeeping` the
    # change edits"
    live = %w[
      spec/integration/timekeeping/alerts_live_spec.rb
      spec/integration/timekeeping/handoff_live_spec.rb
      spec/integration/timekeeping/live_instance_generation_spec.rb
    ]
    bases = []
    rspec_calls = []
    TimekeepingLiveSpecs.run(
      env: { "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_REF_NAME" => "42/merge", "GITHUB_BASE_REF" => "main" },
      out: StringIO.new, err: StringIO.new,
      live_specs: live,
      full_run_branches: %w[develop main stable-3-0 production],
      changed_paths: lambda { |base|
        bases << base
        ["spec/integration/timekeeping/handoff_live_spec.rb", "app/models/user.rb"]
      },
      run_rspec: ->(specs) { rspec_calls << specs; 0 }
    )

    expect(bases).to eq(["origin/main"])
    expect(rspec_calls).to eq([["spec/integration/timekeeping/handoff_live_spec.rb"]])
  end
end

RSpec.describe "TimekeepingLiveSpecs" do
  it "with an empty selection, exits 0 with a no live spec line and never calls rspec" do
    # "When the selection is empty, the job still reports success with a line that says no live spec was
    # selected, so a required check never hangs"
    out = StringIO.new
    rspec_calls = []
    status = TimekeepingLiveSpecs.run(
      env: { "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_REF_NAME" => "42/merge", "GITHUB_BASE_REF" => "main" },
      out: out, err: StringIO.new,
      live_specs: %w[spec/integration/timekeeping/alerts_live_spec.rb spec/integration/timekeeping/handoff_live_spec.rb],
      full_run_branches: %w[develop main stable-3-0 production],
      changed_paths: ->(_base) { ["app/models/user.rb", "spec/integration/timekeeping/local_relay_spec.rb"] },
      run_rspec: ->(specs) { rspec_calls << specs; 0 }
    )

    expect(status).to eq(0)
    expect(out.string).to match(/no live Timekeeping spec was selected/i)
    # rspec with no file arguments would run the whole suite, so it must not be called at all.
    expect(rspec_calls).to be_empty
  end
end

RSpec.describe "TimekeepingLiveSpecs" do
  it "when git cannot list the changed files, exits non-zero instead of reporting an empty selection" do
    out = StringIO.new
    err = StringIO.new
    rspec_calls = []
    status = TimekeepingLiveSpecs.run(
      env: { "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_REF_NAME" => "42/merge", "GITHUB_BASE_REF" => "main" },
      out: out, err: err,
      live_specs: %w[spec/integration/timekeeping/alerts_live_spec.rb],
      full_run_branches: %w[develop main stable-3-0 production],
      changed_paths: ->(_base) { raise TimekeepingLiveSpecs::GitError, "fatal: bad revision 'origin/main...HEAD'" },
      run_rspec: ->(specs) { rspec_calls << specs; 0 }
    )

    expect(status).not_to eq(0)
    expect(err.string).not_to be_empty
    expect(out.string).not_to match(/no live Timekeeping spec was selected/i)
    expect(rspec_calls).to be_empty
  end
end

RSpec.describe "TimekeepingLiveSpecs" do
  it "on a push to main, runs the full live set without computing a diff" do
    # "On a push to main, the job runs the full `spec/integration/timekeeping` live set, as today"
    live = %w[
      spec/integration/timekeeping/alerts_live_spec.rb
      spec/integration/timekeeping/handoff_live_spec.rb
      spec/integration/timekeeping/live_instance_generation_spec.rb
    ]
    diff_calls = []
    rspec_calls = []
    TimekeepingLiveSpecs.run(
      env: { "GITHUB_EVENT_NAME" => "push", "GITHUB_REF_NAME" => "main", "GITHUB_BASE_REF" => "" },
      out: StringIO.new, err: StringIO.new,
      live_specs: live,
      full_run_branches: %w[develop main stable-3-0 production],
      changed_paths: ->(base) { diff_calls << base; [] },
      run_rspec: ->(specs) { rspec_calls << specs; 0 }
    )

    expect(diff_calls).to be_empty
    expect(rspec_calls).to eq([live])
  end
end

RSpec.describe "TimekeepingLiveSpecs" do
  it "selects the full live set for each named full-set path and nothing for near-miss paths" do
    # "A pull request that changes `lib/timekeeping`, `timekeeping/`, `app/services/timekeeping`, `db/`, the live
    # support files or the workflow itself runs the full `spec/integration/timekeeping` live set"
    live = %w[
      spec/integration/timekeeping/alerts_live_spec.rb
      spec/integration/timekeeping/handoff_live_spec.rb
      spec/integration/timekeeping/live_instance_generation_spec.rb
    ]
    full_set_paths = %w[
      lib/timekeeping/handoff.rb
      timekeeping/Gemfile.lock
      app/services/timekeeping/relay.rb
      db/schema.rb
      spec/support/timekeeping/live_instance.rb
      .github/workflows/validations.yml
      script/ci/timekeeping_live_specs.rb
    ]
    near_misses = %w[
      lib/timekeeping_demo/x.rb
      dbx/x.rb
      spec/lib/timekeeping/x.rb
      spec/integration/timekeeping_other/x_live_spec.rb
      spec/integration/timekeeping/local_relay_spec.rb
      app/models/user.rb
    ]

    full_set_paths.each do |path|
      expect(TimekeepingLiveSpecs.selection(changed_paths: [path], live_specs: live)).to eq(live), path
    end
    near_misses.each do |path|
      expect(TimekeepingLiveSpecs.selection(changed_paths: [path], live_specs: live)).to eq([]), path
    end
  end
end

RSpec.describe "TimekeepingLiveSpecs" do
  it "selects an added live spec and a renamed one by its new path, and never a deleted one" do
    # live_specs holds only files on disk, so a deleted or renamed-away path is absent from it.
    live = %w[
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

    expect(TimekeepingLiveSpecs.selection(changed_paths: changed, live_specs: live)).to eq(
      %w[
        spec/integration/timekeeping/billing_live_spec.rb
        spec/integration/timekeeping/handoff_renamed_live_spec.rb
      ]
    )
  end
end

RSpec.describe "TimekeepingLiveSpecs" do
  it "chooses a full run for release-branch pushes and manual runs, and a diff base for pull requests and feature pushes" do
    branches = %w[develop main stable-3-0 production]
    base = ->(event, ref, base_ref = "") do
      TimekeepingLiveSpecs.comparison_base(event_name: event, ref_name: ref, base_ref: base_ref,
                                           full_run_branches: branches)
    end

    expect(base.call("push", "main")).to be_nil
    expect(base.call("push", "develop")).to be_nil
    expect(base.call("push", "production")).to be_nil
    expect(base.call("workflow_dispatch", "feature/x")).to be_nil
    expect(base.call("push", "feature/x")).to eq("origin/main")
    expect(base.call("pull_request", "42/merge", "stable-3-0")).to eq("origin/stable-3-0")
    expect { base.call("pull_request", "42/merge", "") }.to raise_error(ArgumentError)
  end
end

RSpec.describe "TimekeepingLiveSpecs" do
  it "finds exactly the three live specs in the real spec/integration/timekeeping directory" do
    # owned_entries_spec.rb and regression_adapter_spec.rb also need TIMEKEEPING_REGRESSION=1, and
    # local_relay_spec.rb has no live gate, so none of them belongs in the live set.
    expect(TimekeepingLiveSpecs.live_specs(root: Rails.root.to_s)).to eq(
      %w[
        spec/integration/timekeeping/alerts_live_spec.rb
        spec/integration/timekeeping/handoff_live_spec.rb
        spec/integration/timekeeping/live_instance_generation_spec.rb
      ]
    )
  end
end

RSpec.describe "TimekeepingLiveSpecs" do
  it "reads the release branches from the workflow's pull_request trigger" do
    workflow_path = Rails.root.join(".github/workflows/validations.yml").to_s

    expect(TimekeepingLiveSpecs.full_run_branches(workflow_path: workflow_path))
      .to contain_exactly("develop", "main", "stable-3-0", "production")
  end
end

RSpec.describe TimekeepingLiveSpecs do
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
  end
end

RSpec.describe TimekeepingLiveSpecs do
  it "lists only the files the branch adds, edits or deletes since its merge base, not commits main gained later" do
    Dir.mktmpdir do |tmp|
      git = lambda do |dir, *args|
        output, status = Open3.capture2e(
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
      git.call(origin, "commit", "-q", "-m", "base")

      clone = File.join(tmp, "clone")
      git.call(tmp, "clone", "-q", origin, clone)
      git.call(clone, "checkout", "-q", "-b", "feature")
      write.call(clone, "spec/integration/timekeeping/alerts_live_spec.rb", "two\n")
      write.call(clone, "spec/integration/timekeeping/new_live_spec.rb", "new\n")
      git.call(clone, "rm", "-q", "spec/integration/timekeeping/handoff_live_spec.rb")
      git.call(clone, "add", "-A")
      git.call(clone, "commit", "-q", "-m", "feature")

      # main moves on after the branch was cut; its commit is not part of the change.
      write.call(origin, "app/models/later_on_main.rb", "later\n")
      git.call(origin, "add", "-A")
      git.call(origin, "commit", "-q", "-m", "later on main")

      paths = Dir.chdir(clone) { described_class.changed_paths("origin/main") }

      expect(paths.sort).to eq(
        %w[
          spec/integration/timekeeping/alerts_live_spec.rb
          spec/integration/timekeeping/handoff_live_spec.rb
          spec/integration/timekeeping/new_live_spec.rb
        ]
      )
    end
  end
end

RSpec.describe TimekeepingLiveSpecs do
  it "on a pull request that changes lib/timekeeping, timekeeping/, app/services/timekeeping, db/, a live support file or the workflow, runs the full live set" do
    live = %w[
      spec/integration/timekeeping/alerts_live_spec.rb
      spec/integration/timekeeping/handoff_live_spec.rb
      spec/integration/timekeeping/live_instance_generation_spec.rb
    ]
    env = { "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_REF_NAME" => "507/merge", "GITHUB_BASE_REF" => "main" }

    # "A pull request that changes `lib/timekeeping`, `timekeeping/`, `app/services/timekeeping`, `db/`,
    # the live support files or the workflow itself runs the full `spec/integration/timekeeping` live set"
    %w[
      lib/timekeeping/handoff.rb
      timekeeping/Gemfile
      app/services/timekeeping/relay.rb
      db/schema.rb
      spec/support/timekeeping/live_instance.rb
      .github/workflows/validations.yml
    ].each do |trigger|
      rspec_calls = []
      described_class.run(
        env:, out: StringIO.new, err: StringIO.new,
        live_specs: live,
        full_run_branches: %w[develop main stable-3-0 production],
        changed_paths: ->(_base) { ["spec/integration/timekeeping/alerts_live_spec.rb", trigger] },
        run_rspec: ->(specs) { rspec_calls << specs; 0 }
      )

      expect(rspec_calls).to eq([live]), "#{trigger} did not select the full live set"
    end
  end
end

RSpec.describe "script/ci/timekeeping_live_specs.rb" do
  # "When the selection is empty, the job still reports success with a line that says no live spec was selected,
  # so a required check never hangs" - a git failure is not an empty selection, so it must not take that green path.
  it "fails the live step instead of reporting an empty selection when the pull request diff cannot be read" do
    out = StringIO.new
    err = StringIO.new
    rspec_calls = []
    failing_diff = ->(_base) { raise TimekeepingLiveSpecs::GitError, "fatal: bad revision 'origin/main...HEAD'" }

    status = TimekeepingLiveSpecs.run(
      env: { "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_REF_NAME" => "507/merge", "GITHUB_BASE_REF" => "main" },
      out: out,
      err: err,
      live_specs: ["spec/integration/timekeeping/alerts_live_spec.rb", "spec/integration/timekeeping/handoff_live_spec.rb"],
      full_run_branches: %w[develop main stable-3-0 production],
      changed_paths: failing_diff,
      run_rspec: ->(specs) { rspec_calls << specs; 0 }
    )

    expect(status).not_to eq(0)
    expect(rspec_calls).to be_empty
    expect(out.string + err.string).not_to match(/no live timekeeping spec was selected/i)
    expect(err.string).to include("bad revision")
  end
end

RSpec.describe "script/ci/timekeeping_live_specs.rb" do
  # "On a push to main, the job runs the full `spec/integration/timekeeping` live set, as today"
  it "runs the full live set on a push to main without computing a diff that could shrink it" do
    live = [
      "spec/integration/timekeeping/alerts_live_spec.rb",
      "spec/integration/timekeeping/handoff_live_spec.rb",
      "spec/integration/timekeeping/live_instance_generation_spec.rb"
    ]
    diff_calls = []
    rspec_calls = []

    TimekeepingLiveSpecs.run(
      env: { "GITHUB_EVENT_NAME" => "push", "GITHUB_REF_NAME" => "main", "GITHUB_BASE_REF" => "" },
      out: StringIO.new,
      err: StringIO.new,
      live_specs: live,
      full_run_branches: %w[develop main stable-3-0 production],
      changed_paths: ->(base) { diff_calls << base; [] },
      run_rspec: ->(specs) { rspec_calls << specs; 0 }
    )

    expect(diff_calls).to be_empty
    expect(rspec_calls).to eq([live])
  end
end

RSpec.describe "script/ci/timekeeping_live_specs.rb" do
  # "On a pull request, the live job runs only the live specs under `spec/integration/timekeeping` that the change
  # adds or edits" - without a base branch the change's own files cannot be known.
  it "refuses a pull request event that carries no base branch instead of selecting from a guessed base" do
    branches = %w[develop main stable-3-0 production]

    expect do
      TimekeepingLiveSpecs.comparison_base(event_name: "pull_request", ref_name: "507/merge", base_ref: "",
                                           full_run_branches: branches)
    end.to raise_error(ArgumentError)
    expect do
      TimekeepingLiveSpecs.comparison_base(event_name: "pull_request", ref_name: "507/merge", base_ref: nil,
                                           full_run_branches: branches)
    end.to raise_error(ArgumentError)
  end
end

RSpec.describe "script/ci/timekeeping_live_specs.rb" do
  # "A pull request that changes `lib/timekeeping`, `timekeeping/`, `app/services/timekeeping`, `db/`, the live
  # support files or the workflow itself runs the full `spec/integration/timekeeping` live set"
  it "does not treat paths that only share a prefix with a trigger directory as full-set triggers" do
    near_misses = %w[
      lib/timekeeping_demo/runner.rb
      dbx/seed.rb
      db_tools/restore.rb
      spec/lib/timekeeping/handoff_spec.rb
      app/services/timekeeping_reports/export.rb
      spec/support/timekeeping_extra/helper.rb
      .github/workflows/validations.yml.bak
    ]

    expect(near_misses.select { |path| TimekeepingLiveSpecs.full_set_trigger?(path) }).to eq([])
    expect(TimekeepingLiveSpecs.full_set_trigger?("lib/timekeeping/handoff.rb")).to be(true)
    expect(TimekeepingLiveSpecs.full_set_trigger?("db/schema.rb")).to be(true)
  end
end

RSpec.describe "script/ci/timekeeping_live_specs.rb" do
  # "On a pull request, the live job runs only the live specs under `spec/integration/timekeeping` that the change
  # adds or edits, plus the live specs that load a support file under `spec/support/timekeeping` the change edits"
  it "never hands rspec a deleted, renamed-away or out-of-directory spec path from the diff" do
    on_disk = [
      "spec/integration/timekeeping/alerts_live_spec.rb",
      "spec/integration/timekeeping/renamed_live_spec.rb"
    ]
    changed = [
      "spec/integration/timekeeping/removed_live_spec.rb",
      "spec/integration/timekeeping/old_name_live_spec.rb",
      "spec/integration/timekeeping/renamed_live_spec.rb",
      "spec/integration/timekeeping_other/x_live_spec.rb",
      "spec/integration/timekeeping/local_relay_spec.rb",
      "spec/integration/timekeeping/a; rm -rf ~_live_spec.rb"
    ]

    expect(TimekeepingLiveSpecs.selection(changed_paths: changed, live_specs: on_disk))
      .to eq(["spec/integration/timekeeping/renamed_live_spec.rb"])
  end
end

RSpec.describe "script/ci/timekeeping_live_specs.rb" do
  # An empty list here would read as "no live spec touched" and pass the required check with nothing run.
  it "raises a git error for a base branch that does not exist rather than returning no changed paths" do
    Dir.chdir(Rails.root) do
      expect { TimekeepingLiveSpecs.changed_paths("origin/timekeeping-live-specs-no-such-branch") }
        .to raise_error(TimekeepingLiveSpecs::GitError)
    end
  end
end

RSpec.describe "script/ci/timekeeping_live_specs.rb" do
  it "reports the no-spec line and succeeds on a push to main when no live spec exists on disk" do
    out = StringIO.new
    rspec_calls = []

    status = TimekeepingLiveSpecs.run(
      env: { "GITHUB_EVENT_NAME" => "push", "GITHUB_REF_NAME" => "main", "GITHUB_BASE_REF" => "" },
      out: out, err: StringIO.new,
      live_specs: [],
      full_run_branches: %w[develop main stable-3-0 production],
      changed_paths: ->(_base) { raise "a push to main must not compute a diff" },
      run_rspec: ->(specs) { rspec_calls << specs; 0 }
    )

    expect(status).to eq(0)
    expect(out.string).to include("No live Timekeeping spec was selected for this change.")
    expect(rspec_calls).to be_empty
  end
end
