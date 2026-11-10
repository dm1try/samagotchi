# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
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
      AtomicFile.write(File.join(dir, FILE), JSON.generate({ "pid" => pid, "at" => Time.now.iso8601(6) }))
    end

    # Claim the start of +session_id+'s worker: write the marker only when
    # no fresh one holds it (a link(2) of a written temp file: of starters
    # racing, one wins). A stale or dead one is taken over (renamed away,
    # then checked to be the one judged, so a takeover never removes a new
    # claim), and so is a fresh one written before +over_before+ (a stop
    # cancels the starts before it, not the ones after it).
    # @param pid [Integer] the process the hold lasts for (#mark)
    # @param over_before [Time, nil] take over a start marked at or before it
    # @return [Boolean] whether this caller holds the start now
    def claim(session_id, state_dir:, pid: Process.pid, over_before: nil)
      dir = Session.session_dir(session_id, state_dir: state_dir)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, FILE)
      temp = File.join(dir, "#{FILE}.#{Process.pid}.#{SecureRandom.hex(4)}")
      File.write(temp, JSON.generate({ "pid" => pid, "at" => Time.now.iso8601(6) }))
      3.times do
        File.link(temp, path)
        return true
      rescue Errno::EEXIST
        seen = read_raw(path) or next
        return false if holds?(seen, over_before)
        return false unless take_over(path, seen)
      end
      false
    ensure
      FileUtils.rm_f(temp) if temp
    end

    # Move the marker +seen+ out of the way: false when what was renamed is
    # another claim's (put back), true when it was +seen+ or already gone.
    def take_over(path, seen)
      tomb = "#{path}.old.#{Process.pid}.#{SecureRandom.hex(4)}"
      File.rename(path, tomb)
      return true if File.read(tomb) == seen

      begin
        File.link(tomb, path)
      rescue Errno::EEXIST
        nil
      end
      false
    rescue Errno::ENOENT
      true
    ensure
      FileUtils.rm_f(tomb) if tomb
    end
    private_class_method :take_over

    def read_raw(path)
      File.read(path)
    rescue Errno::ENOENT
      nil
    end
    private_class_method :read_raw

    # Whether the marker text +raw+ holds a start: fresh, its process
    # running, and (with +over_before+) marked after it.
    def holds?(raw, over_before = nil)
      data = JSON.parse(raw)
      at = Time.iso8601(data["at"].to_s)
      return false if Time.now - at > STALE
      return false if over_before && at <= over_before

      process_alive?(data["pid"].to_i)
    rescue JSON::ParserError, ArgumentError, TypeError, RangeError, SystemCallError
      false
    end
    private_class_method :holds?

    def clear(session_id, state_dir:)
      FileUtils.rm_f(File.join(Session.session_dir(session_id, state_dir: state_dir), FILE))
    end

    # Whether a worker is being started for +session_id+ right now: its
    # marker is there, fresh, and the process it names runs.
    def fresh?(session_id, state_dir:)
      raw = read_raw(File.join(Session.session_dir(session_id, state_dir: state_dir), FILE))
      !raw.nil? && holds?(raw)
    rescue SystemCallError
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
