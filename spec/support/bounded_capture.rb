# frozen_string_literal: true

# Open3.capture3 with a deadline, for specs that run bin/chi: a chi that
# would hang (a session waiting on stdin, a server that never binds) fails
# the example instead of the suite. No external `timeout` binary (macOS has
# none without coreutils). The command runs in its own process group, and
# the whole group is killed on expiry so no child is left holding the pipes.
#
#   out, err, status = BoundedCapture.capture3(env, RbConfig.ruby, chi, "--help", stdin_data: "", timeout: 20)
module BoundedCapture
  class Expired < StandardError; end

  def self.capture3(*cmd, stdin_data: "", timeout: 20, chdir: nil)
    env = cmd.first.is_a?(Hash) ? cmd.shift : {}
    in_r, in_w = IO.pipe
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    pid = Process.spawn(env, *cmd, in: in_r, out: out_w, err: err_w, pgroup: true, **(chdir ? { chdir: chdir } : {}))
    [in_r, out_w, err_w].each(&:close)
    readers = [out_r, err_r].map { |io| Thread.new { io.read } }
    writer = Thread.new do
      in_w.write(stdin_data)
    rescue Errno::EPIPE
      nil
    ensure
      in_w.close
    end
    waiter = Process.detach(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    left = -> { [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max }

    unless waiter.join(left.call) && readers.all? { |t| t.join(left.call) }
      kill_group(pid)
      waiter.join
      readers.each(&:join)
      raise Expired, "#{cmd.join(" ")} did not finish in #{timeout}s"
    end

    writer.join
    [*readers.map(&:value), waiter.value]
  ensure
    [out_r, err_r].each { |io| io&.close unless io&.closed? }
  end

  def self.kill_group(pid)
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end
end
