# frozen_string_literal: true

require "rails_helper"
require "stringio"
require "tmpdir"

RSpec.describe TimekeepingDemo::Supervisor do
  # True once the process is gone, or is only a zombie left for init to reap.
  def demo_supervisor_process_ended?(pid)
    Process.kill(0, pid)
    File.read("/proc/#{pid}/stat").split[2] == "Z"
  rescue Errno::ESRCH, Errno::ENOENT
    true
  end

  it "stops a process its leader forked even after that leader has exited" do
    Dir.mktmpdir("timekeeping-demo-supervisor") do |dir|
      child_pid_file = File.join(dir, "child.pid")
      # The leader starts a child that ignores TERM, records its pid, then exits.
      script = <<~SH
        sh -c 'trap "" TERM; while :; do sleep 1; done' &
        echo $! > #{child_pid_file}
        exit 3
      SH
      spec = TimekeepingDemo::ProcessSpec.new(name: "monolith_leader", app: :monolith, argv: ["sh", "-c", script],
                                              chdir: dir, env: { "PATH" => ENV.fetch("PATH") })

      expect do
        described_class.new(output: StringIO.new).run([spec], stop_signals: [])
      end.to raise_error(TimekeepingDemo::Supervisor::ProcessFailed, /monolith_leader exited/)

      child_pid = Integer(File.read(child_pid_file).strip, 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep 0.1 until demo_supervisor_process_ended?(child_pid) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      expect(demo_supervisor_process_ended?(child_pid)).to be(true)
    end
  end

  # Runs Ruby code in a separate launcher process that loads only the demo
  # library, as bin/timekeeping-demo does, so the spec can signal it.
  def spawn_demo_supervisor_launcher(code, *args)
    lib = Rails.root.join("lib").to_s
    Process.spawn(RbConfig.ruby, "-I", lib, "-rstringio", "-rtimekeeping_demo/process_spec",
                  "-rtimekeeping_demo/supervisor", "-e", code, *args)
  end

  # Cleans up after a failed example, so no process outlives the spec.
  def kill_demo_supervisor_leftover(pid)
    Process.kill("KILL", pid) if pid
  rescue Errno::ESRCH
    nil
  end

  def wait_for_demo_supervisor_file(path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until File.exist?(path) && !File.read(path).strip.empty?
      raise "#{path} was not written" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
    Integer(File.read(path).strip, 10)
  end

  def demo_supervisor_group_alive?(group)
    Process.kill(0, -group)
    true
  rescue Errno::ESRCH
    false
  end

  it "stops every process group, including a child that ignores TERM, when the launcher receives TERM" do
    Dir.mktmpdir("timekeeping-demo-supervisor") do |dir|
      child_pid_file = File.join(dir, "child.pid")
      # The leader keeps running beside a child that ignores TERM.
      script = <<~SH
        sh -c 'trap "" TERM; while :; do sleep 1; done' &
        echo $! > #{child_pid_file}
        wait
      SH
      code = <<~RUBY
        spec = TimekeepingDemo::ProcessSpec.new(name: "monolith_leader", app: :monolith, argv: ["sh", "-c", ARGV[0]],
                                                chdir: ARGV[1], env: { "PATH" => ENV.fetch("PATH") })
        TimekeepingDemo::Supervisor.new(output: StringIO.new).run([spec], stop_signals: %w[TERM])
      RUBY
      launcher = spawn_demo_supervisor_launcher(code, script, dir)
      begin
        child_pid = wait_for_demo_supervisor_file(child_pid_file)
        Process.kill("TERM", launcher)
        _, status = Process.wait2(launcher)

        expect(status).to be_success
        expect(demo_supervisor_process_ended?(child_pid)).to be(true)
      ensure
        kill_demo_supervisor_leftover(launcher)
        kill_demo_supervisor_leftover(child_pid)
      end
    end
  end

  it "stops a running db:prepare when the launcher receives TERM during preparation" do
    Dir.mktmpdir("timekeeping-demo-supervisor") do |dir|
      prepare_pid_file = File.join(dir, "prepare.pid")
      # Stands in for bin/rails db:prepare: records its pid and keeps running.
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin", "rails"), "#!/bin/sh\necho $$ > #{prepare_pid_file}\nwhile :; do sleep 1; done\n")
      File.chmod(0o755, File.join(dir, "bin", "rails"))
      code = <<~RUBY
        spec = TimekeepingDemo::ProcessSpec.new(name: "monolith_web", app: :monolith, argv: [],
                                                chdir: ARGV[0], env: { "PATH" => ENV.fetch("PATH") })
        TimekeepingDemo::Supervisor.new(output: StringIO.new).prepare([spec])
      RUBY
      launcher = spawn_demo_supervisor_launcher(code, dir)
      begin
        prepare_pid = wait_for_demo_supervisor_file(prepare_pid_file)
        Process.kill("TERM", launcher)
        Process.wait(launcher)

        expect(demo_supervisor_process_ended?(prepare_pid)).to be(true)
      ensure
        kill_demo_supervisor_leftover(launcher)
        kill_demo_supervisor_leftover(prepare_pid)
      end
    end
  end

  it "run appends and flushes each group id to groups_path before the next spawn" do
    Dir.mktmpdir("timekeeping-demo-groups") do |dir|
      groups_path = File.join(dir, "process_groups")
      sleeper = ["sh", "-c", "while :; do sleep 1; done"]
      specs = [
        TimekeepingDemo::ProcessSpec.new(name: "monolith_web", app: :monolith, argv: sleeper,
                                         chdir: dir, env: { "PATH" => ENV.fetch("PATH") }),
        TimekeepingDemo::ProcessSpec.new(name: "monolith_worker", app: :monolith, argv: sleeper,
                                         chdir: dir, env: { "PATH" => ENV.fetch("PATH") }),
        # Exits at once, so run raises ProcessFailed and stops the other two.
        TimekeepingDemo::ProcessSpec.new(name: "timekeeping_web", app: :timekeeping, argv: ["sh", "-c", "exit 0"],
                                         chdir: dir, env: { "PATH" => ENV.fetch("PATH") })
      ]
      seen_at_spawn = []
      spawned = []
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args, **kwargs|
        seen_at_spawn << (File.exist?(groups_path) ? File.read(groups_path) : "")
        original.call(*args, **kwargs).tap { |pid| spawned << pid }
      end

      # "Right after each spawn in `prepare` and `run`, it appends the group id on its own line and flushes it."
      expect do
        described_class.new(output: StringIO.new, groups_path:).run(specs, stop_signals: [])
      end.to raise_error(TimekeepingDemo::Supervisor::ProcessFailed)

      expect(seen_at_spawn).to eq(["", "#{spawned[0]}\n", "#{spawned[0]}\n#{spawned[1]}\n"])
      expect(File.read(groups_path)).to eq(spawned.map { |pid| "#{pid}\n" }.join)
    end
  end

  it "prepare records each db:prepare group id before waiting on it" do
    Dir.mktmpdir("timekeeping-demo-groups") do |dir|
      groups_path = File.join(dir, "process_groups")
      %w[monolith timekeeping].each do |app_dir|
        FileUtils.mkdir_p(File.join(dir, app_dir, "bin"))
        File.write(File.join(dir, app_dir, "bin", "rails"), "#!/bin/sh\nexit 0\n")
        File.chmod(0o755, File.join(dir, app_dir, "bin", "rails"))
      end
      specs = [
        TimekeepingDemo::ProcessSpec.new(name: "monolith_web", app: :monolith, argv: [],
                                         chdir: File.join(dir, "monolith"), env: { "PATH" => ENV.fetch("PATH") }),
        TimekeepingDemo::ProcessSpec.new(name: "timekeeping_web", app: :timekeeping, argv: [],
                                         chdir: File.join(dir, "timekeeping"), env: { "PATH" => ENV.fetch("PATH") })
      ]
      waited = []
      recorded_at_wait = []
      allow(Process).to receive(:wait2).and_wrap_original do |original, pid, *rest|
        waited << pid
        recorded_at_wait << (File.exist?(groups_path) ? File.read(groups_path).lines.map { |line| Integer(line, 10) } : [])
        original.call(pid, *rest)
      end

      # "Right after each spawn in `prepare` and `run`, it appends the group id on its own line and flushes it."
      described_class.new(output: StringIO.new, groups_path:).prepare(specs)

      expect(waited.size).to eq(2)
      expect(waited.zip(recorded_at_wait).map { |pid, recorded| recorded.include?(pid) }).to eq([true, true])
      # The id being waited on is the newest line, so each id is written before its own wait.
      expect(waited.zip(recorded_at_wait).map { |pid, recorded| recorded.last == pid }).to eq([true, true])
      expect(File.read(groups_path).lines.size).to eq(2)
      expect(File.read(groups_path).lines.map { |line| Integer(line, 10) }).to eq(waited)
    end
  end

  # "Do not change how the supervisor stops processes on Ctrl-C or TERM."
  it "with groups_path a TERM to the launcher still stops every group, including a child that ignores TERM" do
    Dir.mktmpdir("timekeeping-demo-groups") do |dir|
      child_pid_file = File.join(dir, "child.pid")
      groups_path = File.join(dir, "process_groups")
      script = <<~SH
        sh -c 'trap "" TERM; while :; do sleep 1; done' &
        echo $! > #{child_pid_file}
        wait
      SH
      code = <<~RUBY
        spec = TimekeepingDemo::ProcessSpec.new(name: "monolith_leader", app: :monolith, argv: ["sh", "-c", ARGV[0]],
                                                chdir: ARGV[1], env: { "PATH" => ENV.fetch("PATH") })
        TimekeepingDemo::Supervisor.new(output: StringIO.new, groups_path: ARGV[2]).run([spec], stop_signals: %w[TERM])
      RUBY
      launcher = spawn_demo_supervisor_launcher(code, script, dir, groups_path)
      child_pid = nil
      begin
        child_pid = wait_for_demo_supervisor_file(child_pid_file)
        Process.kill("TERM", launcher)
        _, status = Process.wait2(launcher)

        expect(status).to be_success
        expect(demo_supervisor_process_ended?(child_pid)).to be(true)
        recorded = File.read(groups_path).lines.map(&:strip).reject(&:empty?).map { |line| Integer(line, 10) }
        expect(recorded.size).to eq(1)
        expect(recorded.none? { |group| demo_supervisor_group_alive?(group) }).to be(true)
      ensure
        kill_demo_supervisor_leftover(launcher)
        kill_demo_supervisor_leftover(child_pid)
      end
    end
  end

  it "leaves every spawned group id in the file, so the groups can be killed after a KILLed launcher" do
    Dir.mktmpdir("timekeeping-demo-groups") do |dir|
      groups_path = File.join(dir, "process_groups")
      code = <<~RUBY
        env = { "PATH" => ENV.fetch("PATH") }
        specs = %w[monolith_web timekeeping_web].map do |name|
          TimekeepingDemo::ProcessSpec.new(name:, app: name.split("_").first.to_sym, argv: ["sleep", "60"],
                                           chdir: ARGV[0], env:)
        end
        TimekeepingDemo::Supervisor.new(output: StringIO.new, groups_path: ARGV[1]).run(specs, stop_signals: %w[TERM])
      RUBY
      launcher = spawn_demo_supervisor_launcher(code, dir, groups_path)
      recorded = []
      begin
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        until recorded.size == 2 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.05
          recorded = File.exist?(groups_path) ? File.read(groups_path).lines.map { |line| Integer(line, 10) } : []
        end
        Process.kill("KILL", launcher)
        Process.wait(launcher)

        expect(recorded.size).to eq(2)
        expect(recorded.all? { |group| demo_supervisor_group_alive?(group) }).to be(true)
        recorded.each { |group| Process.kill("KILL", -group) }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep 0.05 until recorded.none? { |group| demo_supervisor_group_alive?(group) } ||
                         Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        expect(recorded.none? { |group| demo_supervisor_group_alive?(group) }).to be(true)
      ensure
        [launcher, *recorded.map { |group| -group }].each { |target| kill_demo_supervisor_leftover(target) }
      end
    end
  end

  it "writes no file when groups_path is nil" do
    Dir.mktmpdir("timekeeping-demo-groups") do |dir|
      spec = TimekeepingDemo::ProcessSpec.new(name: "monolith_web", app: :monolith, argv: ["sh", "-c", "exit 0"],
                                              chdir: dir, env: { "PATH" => ENV.fetch("PATH") })

      expect do
        described_class.new(output: StringIO.new).run([spec], stop_signals: [])
      end.to raise_error(TimekeepingDemo::Supervisor::ProcessFailed)
      expect(Dir.children(dir)).to be_empty
    end
  end
end
