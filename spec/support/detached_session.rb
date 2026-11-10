# frozen_string_literal: true

require "samagotchi/session"
require "samagotchi/owner_lock"

# A `chi -p X` (no --non-interactive) detaches: the session's worker keeps
# running after the command returns, and a spec whose temp dir holds the
# state would race the worker's writes at teardown (Errno::ENOTEMPTY) and
# leak the worker. stop_detached_session ends that worker and waits until
# its process is gone. A spec requires this file and includes the module.
#
#   out, = run_chi("-p", "hi", env: env, chdir: dir)
#   stop_detached_session(out, env: env, chdir: dir)
module SpecDetachedSession
  REATTACH = /Re-attach with: chi --attach (\h{8})/

  # The worker pid is read from the owner lock the worker holds on its
  # session folder (OwnerLock.owner, kind "worker"), before the stop; after
  # `chi sessions stop` the wait is on that pid being gone (kill 0), then
  # on the lock being free. A no-op when +out+ names no session.
  # @param out [String] the stdout of the detached run (its "Re-attach with" line)
  def stop_detached_session(out, env:, chdir: nil)
    sid = out[REATTACH, 1]
    return unless sid

    state_dir = Samagotchi::Session.default_state_dir(env: env)
    id = Samagotchi::Session.resolve_id(sid, state_dir: state_dir)
    dir = Samagotchi::Session.session_dir(id, state_dir: state_dir)
    pid = Samagotchi::OwnerLock.owner(dir)&.pid
    run_chi("sessions", "stop", id, env: env, chdir: chdir, timeout: 60)
    return unless pid

    wait_for("worker #{pid} of session #{sid} to exit", timeout: 30) { !process_alive?(pid) }
    wait_for("session #{sid}'s owner lock to be free", timeout: 30) { Samagotchi::OwnerLock.owner(dir).nil? }
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end
end
