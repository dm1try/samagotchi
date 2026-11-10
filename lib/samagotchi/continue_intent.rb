# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "atomic_file"
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

    # The intent as read: the successor's id (nil when it names no valid
    # one), the ids archived before the continue, and the ones it archived
    # (nil when the file has no list: written before the archive).
    # CROSS-VERSION: another chi's repair reads this file
    # (spec/compat/readers_spec.rb).
    Intent = Data.define(:successor_id, :previously_archived, :archived_ids)

    module_function

    # Write the intent at +path+ (the continue's one writer).
    # @param archived_ids [Array<String>, nil] nil: not archived yet (not written)
    def write(path, successor_id:, previously_archived:, archived_ids: nil)
      data = { successor_id: successor_id, previously_archived: previously_archived, archived_ids: archived_ids }.compact
      AtomicFile.write(path, "#{JSON.generate(data)}\n", perm: 0o600)
    end

    # The intent at +path+; a file that isn't a JSON object reads as one
    # naming nothing.
    # @return [Intent]
    # @raise [JSON::ParserError, SystemCallError] it doesn't parse, or is gone
    def read(path)
      data = JSON.parse(File.read(path))
      data = {} unless data.is_a?(Hash)
      successor = data["successor_id"]
      archived = data["archived_ids"].is_a?(Array) ? data["archived_ids"].select { |id| Session.valid_id?(id) } : nil
      Intent.new(successor_id: Session.valid_id?(successor) ? successor : nil,
                 previously_archived: Array(data["previously_archived"]).select { |id| Session.valid_id?(id) },
                 archived_ids: archived)
    end

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

      read(path).successor_id
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # The block under a shared hold of +id+'s continue lock, so no continue
    # of it starts until the block returns (its exclusive lock waits); the
    # block's argument is false when a continue holds the lock now (not
    # waited for: nothing is held then). A followed send's check and the
    # resume that would un-archive the link run inside it
    # (SessionManager.deliver_turn's follow:).
    # @yieldparam held [Boolean]
    def hold(id, state_dir:)
      return yield(false) unless Session.valid_id?(id)

      dir = Session.session_dir(id, state_dir: state_dir)
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir, LOCK), File::RDWR | File::CREAT, 0o600) do |lock|
        yield(lock.flock(File::LOCK_SH | File::LOCK_NB) ? true : false)
      end
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
