# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "atomic_file"
require_relative "session"

module Samagotchi
  # A continue's "starting" marker on its new link: written before the
  # continue moves delegates there (ChildMove) and spawns the link's worker,
  # removed by that worker once it holds the owner lock (Worker#start). While
  # it is #fresh?, nothing else spawns a worker for the link (SpawnPart's
  # resume_session and wake_for_report, through
  # WorkerPresence#starting?): a ring from a moved child must not
  # start a second one. CROSS-VERSION: the file name and its {pid, at} are
  # read and cleared by other chi versions (spec/worker_contract_spec.rb).
  module StartingMarker
    # <new link dir>/starting: {pid, at}, from the move to the worker's spawn.
    FILE = "starting"
    # A starting marker older than this, or whose process is gone, is left
    # over from a continue that died: it holds nothing back.
    STALE = 60.0

    module_function

    # Hold off a worker for the continue's new link (#fresh?) until its
    # own worker holds it: written before the move, removed by that worker
    # once it has the owner lock (Worker#start).
    def mark(session_id, state_dir:)
      dir = Session.session_dir(session_id, state_dir: state_dir)
      FileUtils.mkdir_p(dir)
      AtomicFile.write(File.join(dir, FILE), JSON.generate({ "pid" => Process.pid, "at" => Time.now.iso8601(3) }))
    end

    def clear(session_id, state_dir:)
      FileUtils.rm_f(File.join(Session.session_dir(session_id, state_dir: state_dir), FILE))
    end

    # Whether a continue is moving delegates to +session_id+ right now: its
    # marker is there, fresh, and the process that wrote it runs.
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
