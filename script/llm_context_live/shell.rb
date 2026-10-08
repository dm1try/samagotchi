# frozen_string_literal: true

require "open3"
require "timeout"

module LLMContextLive
  # A command's end: its exit status (nil when it timed out), stdout and
  # stderr.
  Ran = Data.define(:status, :out, :err) do
    def ok? = status&.zero?
  end

  # Runs commands for the harness; a spec passes a fake with the same #run.
  class Shell
    # @param argv [Array<String>]
    # @param env [Hash] added to the environment (a nil value unsets it)
    # @param timeout [Numeric, nil] seconds; the process group is killed
    #   past it (this command's own, never another pid)
    # @return [Ran]
    def run(argv, env: {}, chdir: nil, timeout: nil, stdin: nil)
      options = { pgroup: true }
      options[:chdir] = chdir if chdir
      Open3.popen3(env, *argv, **options) do |input, out, err, wait|
        input.write(stdin) if stdin
        input.close
        reader = Thread.new { out.read }
        errors = Thread.new { err.read }
        unless wait.join(timeout)
          stop(wait.pid)
          return Ran.new(status: nil, out: reader.value.to_s, err: errors.value.to_s)
        end
        Ran.new(status: wait.value.exitstatus, out: reader.value.to_s, err: errors.value.to_s)
      end
    end

    private

    def stop(pid)
      Process.kill("-TERM", pid)
      sleep 2
      Process.kill("-KILL", pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
