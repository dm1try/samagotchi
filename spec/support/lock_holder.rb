# frozen_string_literal: true

require "rbconfig"
require "samagotchi/owner_lock"

# A stand-in worker: another ruby process that holds a session folder's
# owner lock (OwnerLock.acquire, kind "worker") and then sleeps. It says
# "locked" on a pipe once it holds the lock, or exits saying why it
# couldn't, and the spec waits on that pipe: no polling OwnerLock.owner while
# it boots (each look takes a shared flock its acquire must retry past) and
# no silent sleep after a missed lock. It boots without Bundler (RUBYOPT
# unset): it needs only lib and the stdlib. Included in every example group
# by spec_helper.
#
#   pid = spawn_lock_holder(session_dir, pgroup: true)
#   pid = spawn_lock_holder(dir, requires: %w[samagotchi/worker_sidecar], args: [port.to_s],
#                           holding: "Samagotchi::WorkerSidecar.new(...).write(ARGV[0])")
#
# +holding+ is Ruby the child runs once it holds the lock, before it says so
# (ARGV[0] is the session folder, then +args+); +ignore_term+ traps TERM;
# +spawn+ options (pgroup:) go to Process.spawn. Returns the pid; reaping it
# (Process.wait or Process.detach) and killing it are the caller's; one
# that fails to say so is killed here.
module SpecLockHolder
  LIB = File.expand_path("../../lib", __dir__)

  def spawn_lock_holder(session_dir, holding: nil, requires: [], args: [], ignore_term: false, sleep_for: 30,
                        timeout: 10, **spawn)
    script = <<~RUBY
      #{'trap("TERM") {}' if ignore_term}
      Samagotchi::OwnerLock.acquire(ARGV[0], kind: "worker") or abort("owner lock unavailable")
      #{holding}
      puts "locked"
      $stdout.flush
      $stdout.reopen(File::NULL)
      $stderr.reopen(File::NULL)
      sleep #{sleep_for}
    RUBY
    ready, writer = IO.pipe
    requires = ["samagotchi/owner_lock", *requires].flat_map { |path| ["-r", path] }
    pid = Process.spawn({ "RUBYOPT" => nil }, RbConfig.ruby, "-I", LIB, *requires, "-e", script, session_dir,
                        *args, out: writer, err: writer, **spawn)
    writer.close
    said = wait_for("the stand-in worker to say it holds its lock", timeout: timeout,
                    seen: -> { process_gone?(pid) ? "it exited" : "it is running" }) do
      ready.wait_readable(0) && (ready.gets || "(exited)")
    end
    expect(said).to eq("locked\n")
    expect(Samagotchi::OwnerLock.owner(session_dir)&.pid).to eq(pid)
    held = pid
  ensure
    ready&.close
    # A holder that never said so is the spec's to end: nothing else knows its pid.
    if pid && !held
      Process.kill("KILL", pid) rescue nil
      Process.detach(pid)
    end
  end
end
