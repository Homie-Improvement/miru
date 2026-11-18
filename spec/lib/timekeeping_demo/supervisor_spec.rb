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
end
