# frozen_string_literal: true

require "open3"
require "rbconfig"

module Samagotchi
  class BundleCommand
    module Try
      class Run
        Result = Data.define(:exit_status, :stdout, :stderr, :session_id, :timed_out)
        INTERRUPT_GRACE = 5
        POLL_INTERVAL = 0.05

        def initialize(sandbox)
          @sandbox = sandbox
        end

        def run(prompt:, options:, timeout:)
          command = [RbConfig.ruby, "-I", Sandbox::LIB_DIR, Sandbox::CHI,
                     "--no-shared", "--non-interactive", "-p", prompt, *child_options(options)]
          Open3.popen3(@sandbox.child_env, *command, chdir: @sandbox.work_dir, pgroup: true, in: File::NULL) do |stdin, stdout, stderr, wait|
            stdin.close
            out_reader = Thread.new { stdout.read }
            err_reader = Thread.new { stderr.read }
            timed_out = false
            interrupt = trap_forwarding(wait.pid)
            begin
              status = wait_for(wait, timeout)
              if status == :timeout
                timed_out = true
                interrupt_child(wait.pid)
                status = wait_for(wait, INTERRUPT_GRACE)
                if status == :timeout
                  kill_group(wait.pid)
                  status = wait.value
                end
              end
            ensure
              restore_traps(interrupt)
            end
            out = out_reader.value
            err = err_reader.value
            code = timed_out ? CLI::Exit::FAILED : process_exit_status(status)
            Result.new(exit_status: code, stdout: out, stderr: err, session_id: err[/^Session: (\S+)/, 1],
                       timed_out: timed_out)
          end
        rescue SystemCallError => e
          raise Sandbox::Error, "chi bundle try: couldn't run chi: #{e.message}"
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

        def trap_forwarding(pid)
          old = {}
          %w[INT TERM].each do |signal|
            old[signal] = Signal.trap(signal) { interrupt_child(pid, signal) }
          end
          old
        end

        def restore_traps(old)
          old.each { |signal, handler| Signal.trap(signal, handler) }
        end

        def interrupt_child(pid, signal = "INT")
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          nil
        end

        def kill_group(pid)
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH
          nil
        end

        def process_exit_status(status)
          status.exitstatus || (128 + status.termsig.to_i)
        end
      end
    end
  end
end
