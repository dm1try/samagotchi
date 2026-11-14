# frozen_string_literal: true

require_relative "../log"

module Samagotchi
  class Engine
    # The running turn as other threads see it: steering into it (now or
    # at the next turn), the drains, the cut, the activity clock and the
    # cancel. Reads @turn_state and @steer_cut; writes nothing of its own.
    module SteeringPart
      # Record that activity happened (user input or a completed turn): the
      # idle jobs' seam (TurnState#record_activity). Each call advances both
      # the last-activity timestamp and the activity sequence.
      # @param now [Float, nil] injectable monotonic time (defaults to now)
      def record_activity(now = nil)
        @turn_state.record_activity(now)
      end

      # @return [Float] monotonic seconds of the last recorded activity
      def last_activity_at
        @turn_state.last_activity_at
      end

      # @return [Integer] monotonically-increasing activity counter (advanced by
      #   #record_activity; lets the idle detector summarize once per idle window)
      def activity_seq
        @turn_state.activity_seq
      end

      # @return [Boolean] true while a turn is in flight (the idle jobs never
      #   fire, nor render, while the model is generating)
      def turn_running?
        @turn_state.running?
      end

      # Put +text+ into the running turn, as a UI's steering does: it joins the
      # conversation at the loop's next iteration boundary as its own user
      # message (kind: "steer", source:). Callable from any thread; never
      # blocks. With no turn running it does nothing (it never starts one).
      # True means queued, not merged: at the after-answer boundary, and when
      # the turn ends first, it is dropped (logged).
      # @return [Boolean] whether it was queued
      def steer(text, source:)
        @turn_state.steer(text, source: source)
      end

      # A message for the running turn from +source+ cuts the generation
      # streaming only thinking (SteerCut#cut_for_steer). Call it after the
      # message is queued, with the #input_epoch read before queueing it.
      # @return [Boolean] whether a generation was cut now
      def cut_for_steer(source, epoch: nil) = @steer_cut.cut_for_steer(source, epoch: epoch)

      # The drains that took input so far: read it before queueing a message
      # for #cut_for_steer.
      def input_epoch = @steer_cut.input_epoch

      # The running generation's phase (SteerCut#generation_snapshot): what
      # Bridge#snapshot puts in current_turn.generation.
      def generation_snapshot = @steer_cut.generation_snapshot

      # Like #steer, for the turn that begins next (a continue turn answered
      # with a text): it joins that turn at its first boundary. Callable from
      # any thread; a turn that never begins keeps it for the next one, unless
      # #drop_carried_steers drops it.
      # @return [Boolean] whether it was queued (false: blank)
      def steer_next_turn(text, source:)
        @turn_state.steer_next_turn(text, source: source)
      end

      # Drop the #steer_next_turn steers no turn began with (the continue turn
      # failed before it began), logged; a no-op once a turn took them.
      def drop_carried_steers
        log_dropped_steers(@turn_state.drop_carried_steers, "not_begun")
      end

      # The drain a turn's loop gets: the caller's lines (a UI's steering; nil
      # in a --non-interactive run) and the plugin steers. At the after-answer
      # boundary the steers are dropped: the model answered, and a nudge would
      # only restart the turn. The steer part fails on its own, never taking
      # the user's lines with it. Items are a String (a user line), a
      # Steer::Line (a worker's input line with its sender) or a steer Hash.
      def turn_drain(pending_input)
        lambda do |at_answer: false|
          lines = pending_input ? Array(pending_input.call) : []
          # The input went to the model: a message that waited to cut is in.
          @steer_cut.delivered! unless lines.empty?
          lines + take_steers(at_answer)
        end
      end
      private :turn_drain

      def take_steers(drop)
        steers = @turn_state.take_steers
        return steers unless drop

        log_dropped_steers(steers, "answered")
        []
      rescue StandardError => e
        Log.warn(:turn, "take_steers_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        []
      end
      private :take_steers

      def log_dropped_steers(steers, why)
        steers.each { |steer| Log.info(:turn, "steer_dropped", source: steer[:source], why: why, chars: steer[:text].length) }
      end
      private :log_dropped_steers

      # @return [CancellationController, nil] active turn's cancellation controller
      def active_cancel_controller
        @turn_state.controller
      end

      # Whether a message a person sent waits for the running turn's next
      # boundary (run_turn's input_waiting: probe): a task_wait or delegate wait
      # returns on it, an execute hands its command over early
      # (PeerView#input_waiting?). False outside a turn, for a turn given no
      # probe, and when the probe raises (warned once a turn; the tool never
      # fails for it).
      def input_waiting?
        probe = @turn_state.input_waiting
        !!probe&.call
      rescue StandardError => e
        Log.warn(:turn, "input_waiting_failed", error: e.class.name, msg: e.message) if @turn_state.input_waiting_failed!
        false
      end

      # Cancel the currently running turn, if any.
      # @param reason [Symbol] cancellation reason
      # @return [Boolean] whether a cancellation was triggered
      def cancel_current_turn!(reason = :manual, turn_id: nil)
        @turn_state.cancel!(reason, turn_id: turn_id)
      end
    end
  end
end
