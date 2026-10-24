# frozen_string_literal: true

require "monitor"
require_relative "message_time"

module Samagotchi
  # The session's due reminders, on their way into a turn.
  #
  # The ReminderStore is the truth (a reminder is due once its interval
  # passed). This adds the names the idle tick found due and handed to the
  # UI's callback (#note_pending): the worker and the REPL run a reminder
  # turn while they are pending. A turn injects whatever is due then
  # (#inject!), which marks it fired and clears the pending names.
  class ReminderQueue
    # @param store [ReminderStore, nil]
    # @param now [#call] the wall clock (a Time) for the injected message's
    #   stamp, when #inject! is given none
    def initialize(store:, now: -> { MessageTime.now })
      @store = store
      @now = now
      @lock = Monitor.new
      @pending = []
    end

    # @return [Array<Hash>] the reminders due now ({name:, description:, interval_minutes:})
    def due
      @store&.due_reminders || []
    end

    # @return [Boolean] whether any reminder is due now (the store's view,
    #   which #inject! would inject), regardless of the pending names
    def due?
      !due.empty?
    end

    # @return [Array<String>] the names queued for a reminder turn
    def pending_names
      @lock.synchronize { @pending.dup }
    end

    # Queue names for a reminder turn (the idle tick's callback).
    def note_pending(names)
      @lock.synchronize { @pending = Array(names).dup }
    end

    # @return [Boolean] whether names are queued (the idle tick waits meanwhile)
    def pending?
      @lock.synchronize { !@pending.empty? }
    end

    def clear_pending!
      @lock.synchronize { @pending = [] }
    end

    # Inject the due reminders into a turn's messages as one tail system
    # message (after the history, before the user's message), mark them
    # all fired under one store lock, and clear the pending names.
    #
    # A tail message, not the head system prompt: changing the head would
    # make the model server re-evaluate the whole conversation's prefix
    # (its KV cache) every interval; a tail costs only the new suffix.
    # The message carries its wall time (MessageTime::KEY, display-only).
    # @param messages [Array<Hash>] the turn's messages (appended to)
    # @param now [Time, nil] the turn's wall time (nil: the clock's)
    # @return [Array<Hash>] the reminders injected (maybe none)
    def inject!(messages, now: nil)
      reminders = due
      return [] if reminders.empty?

      time = now || @now.call
      lines = reminders.map { |r| "  #{r[:name]}: #{r[:description]} (interval: #{r[:interval_minutes]}m)" }.join("\n")
      messages << { role: "system", content: "[SYSTEM: REMINDERS DUE]\n#{lines}\n[END REMINDERS]",
                    MessageTime::KEY => MessageTime.iso(time) }
      @store.mark_fired_batch(reminders.map { |r| r[:name] })
      # Without this a turn's injection leaves a stale name, and the next
      # reminder turn would run with nothing due.
      clear_pending!
      reminders
    end
  end
end
