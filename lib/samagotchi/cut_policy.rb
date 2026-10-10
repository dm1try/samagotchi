# frozen_string_literal: true

require_relative "turn_note"

module Samagotchi
  # What a turn does after a generation was cut (stop_generation: a
  # plugin's cut, or Engine#cut_for_steer's), shared by the native loop
  # (KernelLoop) and the chat loop (ChatLoop::Run); each maps the outcome to
  # its own ending.
  #
  # A generation a plugin cut is an empty answer made early. Queued input
  # (a user's line, a plugin's steer) goes in first, with or without a
  # retry left, and spends no attempt: the model answers it. A steer's cut
  # with nothing queued (its message was taken at a boundary already) is
  # asked again as is. Else it is asked again with its own nudge while the
  # retry budget lasts, else the turn ends as cancelled (hook), with
  # nothing salvaged and without the spent nudge. A Stop that came right
  # after the cut is a plain cancel.
  module CutPolicy
    # :stopped (a Stop after the cut), :again (the turn goes on) or :hook
    # (the turn ends as cancelled by the cut's bundle).
    Outcome = Data.define(:kind) do
      def stopped? = kind == :stopped
      def again? = kind == :again
    end

    STOPPED = Outcome.new(kind: :stopped)
    AGAIN = Outcome.new(kind: :again)
    HOOK = Outcome.new(kind: :hook)

    module_function

    # +cut+: the cut's detail (the stop_generation payload). +emit+ takes an
    # event Hash; +inject+ puts queued input in (true when there was any).
    # +finish_reason+ and +thinking_chars+: the cut generation's, for the
    # retry's row.
    # On :hook the turn controller is cancelled (:hook, +cut+) already.
    def decide(cut:, cancel_controller:, empty_retry:, conversation:, iteration:, emit:, inject:, finish_reason:,
               thinking_chars:)
      return STOPPED if cancel_controller.cancelled?

      # The row under the cut step, above the message it was cut for.
      emit.call({ type: :steer_cut, iteration: iteration, source: cut[:source].to_s }) if cut[:steer]
      return AGAIN if inject.call || cut[:steer]

      if empty_retry.left?
        empty_retry.nudge!(conversation, TurnNote.cut_retry(cut[:by], cut[:reason]),
                           emit: emit, iteration: iteration, finish_reason: finish_reason,
                           thinking_chars: thinking_chars, stopped_by: cut[:by])
        return AGAIN
      end
      empty_retry.drop_nudge!(conversation)
      cancel_controller.cancel!(:hook, cut)
      HOOK
    end
  end
end
