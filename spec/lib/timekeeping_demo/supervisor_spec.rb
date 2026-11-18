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
end
