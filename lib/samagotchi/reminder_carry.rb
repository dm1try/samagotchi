# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "atomic_file"
require_relative "log"
require_relative "reminder_store"

module Samagotchi
  # A restart's hand-off of the session's reminders, which otherwise live only
  # in the worker's Engine: the leaving worker writes `<id>/reminders.json`
  # (Worker#leave_on_request, as it takes a restart) and its successor takes
  # it as it starts (Worker#start), reading and deleting it. Only an asked
  # restart writes one: a stop, an idle exit, a crash and a fallback restart
  # (a TERM) drop the reminders as before, and a stop removes a file left
  # behind (SessionManager.stop_session). A file is honoured only by the same
  # session, within WINDOW of its writing (a successor starts in seconds), so
  # one no successor read can't bring reminders back a day later.
  module ReminderCarry
    FILE = "reminders.json"
    # Seconds a hand-off stays good after it was written.
    WINDOW = 120

    module_function

    def path(session_dir) = File.join(session_dir, FILE)

    # Write +store+'s reminders for the successor; no reminders, no file.
    # @return [Integer] how many were written
    # @raise [SystemCallError] when the write fails (the caller stays up)
    def write(session_dir, session_id:, store:, wall: Time.now)
      entries = store.export(wall: wall)
      if entries.empty?
        remove(session_dir)
        return 0
      end

      body = { "session_id" => session_id, "written_at" => wall.getutc.iso8601(3), "reminders" => entries }
      AtomicFile.write(path(session_dir), "#{JSON.generate(body)}\n", perm: 0o600)
      entries.size
    end

    # Restore the hand-off into +store+ and delete it. A file of another
    # session, outside WINDOW or unreadable, or one found as a stopped
    # session starts, is deleted without restoring (log reminders_carry_dropped).
    # @return [Array<String>] the names restored
    def take(session_dir, session_id:, store:, stopped: false, wall: Time.now)
      file = path(session_dir)
      return [] unless File.exist?(file)

      data = read(file)
      remove(session_dir)
      why = drop_reason(data, session_id, stopped, wall)
      if why
        Log.info(:worker, "reminders_carry_dropped", why: why)
        return []
      end

      names = store.restore(data["reminders"], wall: wall)
      Log.info(:worker, "reminders_carried", count: names.size)
      names
    end

    # @return [true]
    def remove(session_dir)
      FileUtils.rm_f(path(session_dir))
      true
    end

    def read(file)
      data = JSON.parse(File.read(file))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def drop_reason(data, session_id, stopped, wall)
      return :unreadable unless data
      return :stopped if stopped
      return :other_session unless data["session_id"] == session_id

      written = Time.iso8601(data["written_at"].to_s)
      :stale if (wall - written).abs > WINDOW
    rescue ArgumentError
      :stale
    end
    private_class_method :read, :drop_reason
  end
end
