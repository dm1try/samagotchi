# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "../../cli/exit"
require_relative "../../process_group"

module Samagotchi
  class BundleCommand
    module Try
      # The sandboxed child chi of `chi bundle try`, in a process group of
      # its own (ProcessGroup). A --timeout sends it INT (a Ctrl-C: the turn
      # is saved), then after INTERRUPT_GRACE ProcessGroup.stop stops the
      # group and the groups its processes started. After any exit the
      # group is stopped only while something of the child's is still in it
      # (#stop_stragglers): a group signal to a leader reaped with nothing
      # left would reach whatever reuses its pid. What left the group and
      # its parent (a delegate's worker, a task once the child exited) is
      # Sandbox#stop_leftovers', by the records in the sandbox.
      class Run
        Result = Data.define(:exit_status, :stdout, :stderr, :session_id, :timed_out)
        INTERRUPT_GRACE = 5
        READER_GRACE = 2
        GROUP_TERM_GRACE = 0.1
        POLL_INTERVAL = 0.05

        def initialize(sandbox)
          @sandbox = sandbox
        end

        def run(prompt:, options:, timeout:)
          command = [RbConfig.ruby, "-I", Sandbox::LIB_DIR, Sandbox::CHI,
                     "--no-shared", "--non-interactive", "-p", prompt, *child_options(options)]
          trap_state, old_traps = trap_forwarding
          pid = nil
          streams = []
          readers = []
          begin
            Open3.popen3(@sandbox.child_env, *command, chdir: @sandbox.work_dir, pgroup: true, in: File::NULL) do |stdin, stdout, stderr, wait|
              pid = wait.pid
              streams = [stdout, stderr]
              stdin.close
              readers = streams.map { |stream| Thread.new { read_stream(stream) } }
              attach_child(trap_state, pid, wait)
              timed_out = false
              status = wait_for(wait, timeout)
              if status == :timeout
                timed_out = true
                ProcessGroup.signal(pid, "INT")
                status = wait_for(wait, INTERRUPT_GRACE)
                if status == :timeout
                  ProcessGroup.stop(pid, grace: GROUP_TERM_GRACE, poll: POLL_INTERVAL, stopped: -> { !wait.alive? })
                  status = wait.value
                end
              end
              trap_state[:pid] = nil
              out, err = finish_readers(readers, streams)
              code = timed_out ? CLI::Exit::FAILED : exit_code(status, trap_state)
              Result.new(exit_status: code, stdout: out, stderr: err, session_id: err[/^Session: (\S+)/, 1],
                         timed_out: timed_out)
            end
          rescue SystemCallError => e
            raise Sandbox::Error, "chi bundle try: couldn't run chi: #{e.message}"
          ensure
            trap_state[:pid] = nil
            stop_stragglers(pid) if pid
            close_streams(streams)
            stop_readers(readers)
            restore_traps(old_traps)
          end
        end

        private

        def child_options(options)
          args = []
          %i[model toolkit thinking].each do |key|
            args.concat(["--#{key}", options[key]]) if options[key]
          end
          %i[memory mute].each do |key|
            Array(options[key]).each { |value| args.concat(["--#{key}", value]) }
          end
          args
        end

        def wait_for(wait, seconds)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
          loop do
            return wait.value if wait.join(POLL_INTERVAL)
            return :timeout if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          end
        end

        def trap_forwarding
          state = { pid: nil, wait: nil, pending: nil, interrupted: false }
          old = {}
          %w[INT TERM].each do |signal|
            old[signal] = Signal.trap(signal) do
              if state[:pid]
                # Not once its waiter reaped it: that group may be gone.
                if state[:wait]&.alive?
                  state[:interrupted] ||= signal == "INT"
                  ProcessGroup.signal(state[:pid], signal)
                end
              else
                state[:pending] ||= signal
              end
            end
          end
          [state, old]
        end

        def attach_child(state, pid, wait)
          state[:wait] = wait
          state[:pid] = pid
          pending = state[:pending]
          state[:pending] = nil
          return unless pending

          state[:interrupted] ||= pending == "INT"
          ProcessGroup.signal(pid, pending)
        end

        def restore_traps(old)
          old.each { |signal, handler| Signal.trap(signal, handler) }
        end

        # Stops what is left in the child's group once the child (its
        # leader) is reaped: a descendant still holding its pipes. Only
        # while one is in it: no process left means no group, and the pid
        # may be reused by now. While a member is left the group's id
        # can't be reused; the reaped leader's pid can, so a group whose
        # member is the pid itself is someone else's.
        def stop_stragglers(pid)
          return unless ProcessGroup.signalable?(pid) && ProcessGroup.group_alive?(pid)

          members = ProcessGroup.process_table.select { |_pid, _ppid, group| group == pid }.map(&:first)
          return if members.empty? || members.include?(pid)

          ProcessGroup.stop(pid, grace: GROUP_TERM_GRACE, poll: POLL_INTERVAL,
                                 stopped: -> { !ProcessGroup.group_alive?(pid) })
        end

        def read_stream(stream)
          output = +""
          loop { output << stream.readpartial(16_384) }
        rescue EOFError
          output
        rescue IOError
          raise unless stream.closed?

          output
        end

        def finish_readers(readers, streams)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READER_GRACE
          readers.each do |reader|
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            reader.join([remaining, 0].max)
          end
          close_streams(streams)
          readers.each do |reader|
            reader.join(0.1) if reader.alive?
            reader.kill if reader.alive?
          end
          readers.map { |reader| reader.value.to_s }
        end

        def close_streams(streams)
          streams.each { |stream| stream.close unless stream.closed? }
        end

        def stop_readers(readers)
          readers.each do |reader|
            reader.join(0.1)
            reader.kill if reader.alive?
          end
          readers.each(&:join)
        end

        # A Ctrl-C forwarded to the child is an interrupted run, however it
        # ended: a Ruby still booting (before chi's INT handler) exits 1.
        def exit_code(status, trap_state)
          return CLI::Exit::INTERRUPTED if trap_state[:interrupted] && !status.success?

          process_exit_status(status)
        end

        def process_exit_status(status)
          status.exitstatus || (128 + status.termsig.to_i)
        end
      end
    end
  end
end
