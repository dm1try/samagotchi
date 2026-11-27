# frozen_string_literal: true

require "json"
require_relative "atomic_file"
require_relative "session"
require_relative "session_transition"

module Samagotchi
  # The files a continue (SessionContinue.run) keeps in the previous link's
  # folder while it runs: LOCK, held for its transition, from after the
  # recap to the end (SessionTransition, the one code that flocks it; the
  # new link's own is held with it), and FILE, its
  # intent (the successor's id), written before the link is archived and
  # removed once the successor is saved or the continue is undone. A send
  # (SessionInbox::Head) and a schedule tick (Schedules#continuing_reason)
  # read them to tell a continue in flight from a link nobody continues.
  module ContinueIntent
    # One continue of a session at a time (SessionTransition::LOCK).
    LOCK = SessionTransition::LOCK
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

    # The successor's id of a continue of +id+ in flight: its intent written,
    # its lock held, and the successor saved or its lock held too (a
    # continue holds both). nil when there is none, or the intent is stale
    # or unreadable: no continue holds the lock (a crash left it, and
    # SessionContinue.repair_interrupted undoes it), or another transition
    # holds it over a crashed continue's intent whose successor was never
    # saved and nobody holds (that continue is not coming back), or the
    # holder recorded another kind (a delete, a stop, an archive holding it
    # over a crashed continue's intent: SessionTransition.holder).
    # @return [String, nil]
    def in_flight(id, state_dir:)
      return nil unless Session.valid_id?(id)

      dir = Session.session_dir(id, state_dir: state_dir)
      path = File.join(dir, FILE)
      return nil unless File.file?(path) && SessionTransition.held?(id, state_dir: state_dir)
      return nil if SessionTransition.other_than_continue?(SessionTransition.holder(id, state_dir: state_dir))

      successor = read(path).successor_id
      return nil unless successor
      return successor if Session.exist?(successor, state_dir: state_dir) ||
                          SessionTransition.held?(successor, state_dir: state_dir)

      nil
    rescue JSON::ParserError, SystemCallError
      nil
    end
  end
end
