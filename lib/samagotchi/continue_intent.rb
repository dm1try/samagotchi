# frozen_string_literal: true

require "json"
require_relative "session"

module Samagotchi
  # The files a continue (SessionContinue.run) keeps in the previous link's
  # folder while it runs: LOCK, held for the whole continue, and FILE, its
  # intent (the successor's id), written before the link is archived and
  # removed once the successor is saved or the continue is undone. A send
  # (SessionInbox::Head) and a schedule tick (Schedules#continuing_reason)
  # read them to tell a continue in flight from a link nobody continues.
  module ContinueIntent
    # One continue of a session at a time.
    LOCK = "continue.lock"
    # The intent: { successor_id:, previously_archived:, archived_ids: }.
    FILE = "continue.json"

    module_function

    # The successor's id of a continue of +id+ in flight: its intent written
    # and its lock held. nil when there is none, or the intent is stale (no
    # continue holds the lock: a crash left it, and
    # SessionContinue.repair_interrupted undoes it) or unreadable.
    # @return [String, nil]
    def in_flight(id, state_dir:)
      return nil unless Session.valid_id?(id)

      dir = Session.session_dir(id, state_dir: state_dir)
      path = File.join(dir, FILE)
      return nil unless File.file?(path) && locked?(File.join(dir, LOCK))

      data = JSON.parse(File.read(path))
      successor = data["successor_id"] if data.is_a?(Hash)
      Session.valid_id?(successor) ? successor : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # Whether a continue holds the lock at +path+: a shared try that fails.
    # The try is let go at once (the file is closed).
    def locked?(path)
      File.open(path, File::RDONLY) { |lock| !lock.flock(File::LOCK_SH | File::LOCK_NB) }
    rescue Errno::ENOENT
      false
    end
  end
end
