# frozen_string_literal: true

require_relative "log"

module Samagotchi
  # Who protects a session from a delete (docs/sessions.md, "Deleting a
  # session"): the sibling of SessionStores, which says what a delete
  # removes; this says what refuses it. The retention sweep keeps every
  # protected id, a link's delete is refused by its first #hold and a chain's
  # by its first #chain_hold (SessionManager::DeleteRefused, whose reasons
  # hold the words).
  #
  # A protector is what a PROTECTORS entry builds for a state dir, answering
  # three questions: #protected_ids (Array<String>), #hold(session_id) and
  # #chain_hold(session_id) (a Hold or nil). Schedules is the one protector
  # (Schedules::ProtectionPart: an enabled schedule's anchor, head and
  # resolved target).
  #
  # Fail-closed: a protector that raises is logged and the error re-raised,
  # never read as "unprotected". The sweep (SessionRetention.sweep_if_due)
  # logs retention_failed and deletes nothing (an Unreadable store:
  # retention_skipped, once per sweep interval); a delete raises to its
  # caller, and a store that is there but doesn't read (Unreadable) is its
  # refusal (DeleteRefused :protection_unreadable,
  # SessionManager.refuse_protected!). A missing store protects nothing.
  module SessionProtection
    # +session_id+ the session held, +reason+ the DeleteRefused reason the
    # holder asks for (:scheduled for a link, :chain_scheduled for a chain),
    # +ref+ the holder's id for the words (the schedule id).
    Hold = Data.define(:session_id, :reason, :ref)

    # A protector's store is there but doesn't read (schedules.json not
    # JSON, not a schedules document, a file chi can't open, or one schedule
    # in it that doesn't read): who it protects is unknown, so no session is
    # deleted until it is fixed. Its words, one per condition: the whole
    # file, or one entry (+entry+, its id) and the way to drop that entry.
    class Unreadable < StandardError
      # @param file [String] the store's name, for the words
      # @param error [String] why it doesn't read
      # @param entry [String, nil] the id of the one entry that doesn't read
      def initialize(file, error, entry: nil)
        if entry
          super("schedule entry #{entry} in #{file} is unreadable (#{error}): chi schedule cancel #{entry}, " \
                "or fix the file, before deleting sessions")
        else
          super("#{file} is unreadable (#{error}): fix or remove it before deleting sessions")
        end
      end
    end

    module_function

    # Deferred: schedules.rb requires session_manager, whose removal part
    # requires this file.
    def schedule_protector(state_dir)
      require_relative "schedules"
      Schedules.new(state_dir: state_dir)
    end

    PROTECTORS = { schedule: method(:schedule_protector) }.freeze

    # @return [Array<String>] every id some protector holds (retention keeps them)
    def protected_ids(state_dir:)
      PROTECTORS.flat_map { |name, build| ask(name, build, state_dir, &:protected_ids) }.uniq
    end

    # @return [Hold, nil] the first protector's hold on a delete of +session_id+
    def hold(session_id, state_dir:)
      first_hold(session_id, state_dir) { |protector| protector.hold(session_id) }
    end

    # @return [Hold, nil] the first protector's hold on a delete of the chain
    #   +session_id+ belongs to
    def chain_hold(session_id, state_dir:)
      first_hold(session_id, state_dir) { |protector| protector.chain_hold(session_id) }
    end

    def first_hold(session_id, state_dir, &question)
      PROTECTORS.each do |name, build|
        found = ask(name, build, state_dir, sid: session_id, &question)
        return found if found
      end
      nil
    end
    private_class_method :first_hold

    # An Unreadable store is logged once, by the caller (retention_skipped,
    # or the delete's refusal), not here.
    def ask(name, build, state_dir, sid: nil)
      yield build.call(state_dir)
    rescue Unreadable
      raise
    rescue StandardError => e
      Log.warn(:worker, "protector_failed", protector: name, sid: sid, error: e.class.name, msg: e.message)
      raise
    end
    private_class_method :ask
  end
end
