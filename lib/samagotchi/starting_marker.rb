# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "atomic_file"
require_relative "session"

module Samagotchi
  # A session's "starting" marker: a worker is being started for it. Every
  # spawn writes it (SpawnPart's spawn_worker_for_session: the writer's pid
  # before the spawn, the starter's after; a continue's before it moves
  # delegates to its new link), and the worker removes it once it holds the
  # owner lock (Worker#start). While it is #fresh?, nothing else spawns a
  # worker for the session (WorkerPresence#starting?). CROSS-VERSION: the
  # file name and its {pid, at} are read and cleared by other chi versions
  # (spec/worker_contract_spec.rb).
  module StartingMarker
    # <session dir>/starting: {pid, at}, from the decision to spawn to the
    # worker holding the lock.
    FILE = "starting"
    # A starting marker older than this, or whose process is gone, is left
    # over from a start that died: it holds nothing back.
    STALE = 60.0

    module_function

    # Hold off any other worker for +session_id+ (#fresh?) until the one
    # being started holds it, for as long as +pid+ runs: removed by that
    # worker once it has the owner lock (Worker#start).
    # @param pid [Integer] the process the hold lasts for: the writer, or
    #   the worker's starter once it is spawned
    def mark(session_id, state_dir:, pid: Process.pid)
      dir = Session.session_dir(session_id, state_dir: state_dir)
      FileUtils.mkdir_p(dir)
      AtomicFile.write(File.join(dir, FILE), JSON.generate({ "pid" => pid, "at" => Time.now.iso8601(3) }))
    end

    def clear(session_id, state_dir:)
      FileUtils.rm_f(File.join(Session.session_dir(session_id, state_dir: state_dir), FILE))
    end

    # Whether a worker is being started for +session_id+ right now: its
    # marker is there, fresh, and the process it names runs.
    def fresh?(session_id, state_dir:)
      file = File.join(Session.session_dir(session_id, state_dir: state_dir), FILE)
      return false unless File.exist?(file)

      data = JSON.parse(File.read(file))
      return false if Time.now - Time.iso8601(data["at"].to_s) > STALE

      process_alive?(data["pid"].to_i)
    rescue JSON::ParserError, ArgumentError, SystemCallError
      false
    end

    # Signal 0 only asks whether the process exists.
    def process_alive?(pid)
      return false unless pid.positive?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
  end
end
