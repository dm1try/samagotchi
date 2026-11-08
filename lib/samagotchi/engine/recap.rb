# frozen_string_literal: true

require_relative "../recap_place"

module Samagotchi
  class Engine
    # The idle recap (IdleRecap) and the shared idle scheduler: the recap job
    # rebuilt under the bound session's own recap values, /recap's override,
    # the saved recap. Writes @recap, @recap_awaiting_continue; reads
    # @recap_built_for, @idle_scheduler, @session.
    module RecapPart
      # Snapshot the current session messages as a JSON string for the idle
      # recap. The array is never mutated in place (a turn or a note replaces
      # it), so the reference read here is a consistent snapshot; a dup'd
      # copy is serialized. Never mutates session.messages.
      # @return [String] JSON array of the messages
      def messages_json_for_recap
        snapshot = @session&.messages
        return "[]" if snapshot.nil?

        JSON.generate(AnswerDisplay.strip_all(snapshot).map(&:dup))
      end

      # Emit a :recap_ready event (additive slot) carrying the generated recap
      # and the generation id an observer uses to reject an invalidated recap.
      # +covered+ counts the session messages it summarizes; +created_at+ is
      # the saved recap's (UTC ISO; the UIs show its local time).
      def emit_recap(recap:, generation:, covered: nil, created_at: nil)
        event = { type: :recap_ready, recap: recap, generation: generation, covered: covered }
        event[:created_at] = created_at if created_at
        @session_observer.notify(event)
      end

      # @return [IdleRecap, nil] the idle recap detector, or nil when disabled
      attr_reader :recap

      # Whether a continue offer waits (the Worker's or the one-shot's TurnFlow),
      # for the recap job: this one and any rebuilt one (IdleRecap#awaiting_continue=).
      def recap_awaiting_continue=(callable)
        @recap_awaiting_continue = callable
        @recap&.awaiting_continue = callable
      end

      # The bound session's own recap.* values ({} for none).
      def session_recap_values
        (@session&.settings&.core || {}).select { |key, _| key.start_with?("recap.") }
      end
      private :session_recap_values

      # A new recap job when the bound session's own recap values differ from
      # the ones the current job was built under (none at start): the old one
      # is dropped (an attempt in flight goes stale) and the scheduler swaps
      # it, keeping its one thread. Binding the same session again changes
      # nothing.
      def rebuild_recap!
        return if session_recap_values == @recap_built_for

        old = @recap
        old&.invalidate!
        @recap = build_recap
        @idle_scheduler&.replace_job(old, @recap)
      end

      # /recap on|off|default: the bound session's own recap.enabled (true,
      # false; nil removes it, so config.yml's applies again), and the recap
      # job rebuilt under it at once. It doesn't save: the command says
      # changed: [:recap] and its host saves (Worker#run_command).
      # @param enabled [Boolean, nil]
      # @raise [ArgumentError] no session is bound
      def recap_override=(enabled)
        raise ArgumentError, "no session" unless @session

        core = @session.settings.core.dup
        enabled.nil? ? core.delete(RECAP_ENABLED_KEY) : core[RECAP_ENABLED_KEY] = enabled
        @session.settings = @session.settings.with(core: core)
        rebuild_recap!
      end

      # The bound session's own recap.enabled (/recap on|off, --set), or nil.
      # @return [Boolean, nil]
      def recap_override = @session&.settings&.core&.fetch(RECAP_ENABLED_KEY, nil)

      # Write the recap now, before the session is left (IdleRecap#write_now).
      # @return [String, nil] the recap written, nil when none was (recap off,
      #   nothing new, an error, the timeout)
      def write_recap_now(on_start: nil)
        @recap&.write_now(on_start: on_start)
      end

      # The longest #write_recap_now waits (recap.timeout), nil when no recap
      # is set up.
      # @return [Float, nil]
      def recap_timeout = @recap&.timeout

      # Ask for a recap now (/recap), without waiting for the idle window.
      # @return [Symbol] IdleRecap#request_now's answer, or :off
      def request_recap
        @recap ? @recap.request_now : :off
      end

      # The recap saved with the current session (recap.json), how many
      # user turns came after it (0: it is current), and the stamp of the
      # last turn it covers (RecapPlace: where a page puts it; nil, the count).
      # @return [Hash, nil] {text:, covered:, turns_since:, opening_id:, created_at:}
      def saved_recap
        state = @recap&.state
        return nil unless state

        messages = @session&.messages || []
        covered = state[:covered].to_i
        turns_since = Array(messages).drop(covered).count { |m| Steer.turn_opening?(m) }
        { text: state[:text], covered: covered, turns_since: turns_since, opening_id: RecapPlace.opening_id(messages, covered),
          created_at: state[:created_at] }
      end

      # Start the shared idle scheduler (reminders + optional recap). The recap
      # job is only registered when recap is configured; the reminders job is
      # always present. SessionManager workers call it so reminders can
      # trigger turns; a one-shot never starts it and polls nothing.
      def start_idle
        @idle_scheduler&.start
        self
      end

      # Stop the shared idle scheduler (a worker as it leaves). +join+: wait for a tick under way (IdleScheduler#stop); a
      # caller holding #synchronize_events passes false, since a recap's emit
      # in that tick waits for the same lock.
      def stop_idle(join: true)
        @idle_scheduler&.stop(join: join)
        self
      end
    end
  end
end
