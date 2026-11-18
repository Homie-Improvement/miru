# frozen_string_literal: true

module TimekeepingDemo
  # Starts the demo's processes, each in its own process group with exactly
  # the environment its ProcessSpec holds, and stops all of them together.
  # Every decision about what runs, where and with which keys is made in
  # RuntimePlan; this class only carries it out.
  class Supervisor
    class ProcessFailed < StandardError; end

    STOP_GRACE_SECONDS = 10
    POLL_SECONDS = 0.25
    PREPARE_COMMAND = %w[bin/rails db:prepare].freeze

    def initialize(output: $stderr)
      @output = output
    end

    # Creates or migrates each application's database once, with that
    # application's own environment. Raises ProcessFailed when one fails.
    def prepare(specs)
      specs.uniq(&:app).each do |spec|
        pid = spawn(spec, PREPARE_COMMAND, pgroup: true)
        status = nil
        begin
          _, status = Process.wait2(pid)
        ensure
          # Reached without a status when the wait was interrupted, such as by
          # Ctrl-C or a TERM to the launcher: stop db:prepare with it.
          stop([pid], { pid => "db:prepare" }) unless status
        end
        raise ProcessFailed, "db:prepare failed for #{spec.app} (#{status})" unless status.success?
      end
    end

    # Starts every process and blocks until one of stop_signals arrives, then
    # stops them all. If any process exits on its own, the rest are stopped and
    # ProcessFailed is raised, so the runtime never keeps going with a worker
    # or web app missing.
    def run(specs, stop_signals:)
      stop_pipe, previous_handlers = trap_stop_signals(stop_signals)
      running = {}
      # Each process leads its own group, whose id is the leader's pid. The
      # groups are kept apart from the unreaped leaders because a leader can
      # exit while processes it forked, such as queue workers, keep running.
      groups = []
      specs.each do |spec|
        pid = spawn(spec, spec.argv, pgroup: true)
        running[pid] = spec.name
        groups << pid
        @output.puts "timekeeping-demo: started #{spec.name}"
      end
      exited = wait_for_stop_or_exit(running, stop_pipe.first)
      raise ProcessFailed, "#{exited.fetch(:name)} exited (#{exited.fetch(:status)}); stopped the rest" if exited
    ensure
      stop(groups, running) if groups
      previous_handlers&.each { |signal, handler| Signal.trap(signal, handler) }
      stop_pipe&.each(&:close)
    end

    private

      # The trap handler only writes to a pipe, because a trap handler may not
      # take locks; the main loop reads it. Answers the pipe and the handlers
      # the traps replaced. bin/timekeeping-demo loads this file without
      # Rails, so ActiveSupport's index_with is not available.
      def trap_stop_signals(stop_signals)
        pipe = IO.pipe
        previous = stop_signals.to_h do |signal| # rubocop:disable Rails/IndexWith
          [signal, Signal.trap(signal) { pipe.last.write_nonblock(".", exception: false) }]
        end
        [pipe, previous]
      end

      def wait_for_stop_or_exit(running, stop_requested)
        loop do
          running.each_key do |pid|
            reaped, status = Process.wait2(pid, Process::WNOHANG)
            next unless reaped

            name = running.delete(pid)
            return { name:, status: }
          end
          return nil if stop_requested.wait_readable(POLL_SECONDS)
        end
      end

      # Sends TERM to every process group started, waits up to
      # STOP_GRACE_SECONDS for every member of every group to exit, then KILLs
      # any group still holding a process. A leader that was already reaped
      # does not end its group: the processes it forked are still signalled.
      def stop(groups, running)
        groups.each { |group| signal_group("TERM", group) }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STOP_GRACE_SECONDS
        loop do
          # Reaping keeps an exited leader from staying in its group as a zombie.
          running.delete_if { |pid, _name| reaped?(pid) }
          break if groups.none? { |group| group_alive?(group) }
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep POLL_SECONDS
        end
        groups.each { |group| signal_group("KILL", group) }
        running.each_key { |pid| reap(pid) }
        running.clear
      end

      def signal_group(signal, group)
        Process.kill(signal, -group)
      rescue Errno::ESRCH
        nil
      end

      def group_alive?(group)
        Process.kill(0, -group)
        true
      rescue Errno::ESRCH
        false
      end

      def reaped?(pid)
        !Process.wait(pid, Process::WNOHANG).nil?
      rescue Errno::ECHILD
        true
      end

      def reap(pid)
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end

      # unsetenv_others drops everything the caller holds, so the process gets
      # only spec.env. The unbundled block keeps the launcher's own Bundler
      # setup from leaking in when it runs under one.
      def spawn(spec, argv, pgroup:)
        with_unbundled_env do
          Process.spawn(spec.env, *argv, chdir: spec.chdir, unsetenv_others: true, pgroup: pgroup || nil)
        end
      end

      def with_unbundled_env(&)
        defined?(Bundler) ? Bundler.with_unbundled_env(&) : yield
      end
  end
end
