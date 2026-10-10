# frozen_string_literal: true

require_relative "config"
require_relative "log"
require_relative "steer"
require_relative "generation_phase"
require_relative "waiting_steer"

module Samagotchi
  # A message for the running turn cutting the generation it came during:
  # what the generation streams (GenerationPhase, fed by #observe from the
  # turn's stream) and a message that came too early to cut (WaitingSteer).
  # The Engine's seam: Bridge and TerminalUI call Engine#cut_for_steer and
  # #input_epoch, the turn thread feeds #observe and #delivered!, and the
  # turn's end calls #finished!. Callable from any thread: GenerationPhase
  # and WaitingSteer hold their own locks.
  class SteerCut
    # A chunk's thinking and text. A chunk without the lanes (no loop of
    # ours sends one) counts as text.
    def self.lanes(event)
      text = event.key?(:text) ? event[:text] : event[:content]
      { thinking: event[:thinking].to_s, text: text.to_s }
    end

    # steer.cut_after: how long a generation streams only thinking before a
    # message may cut it, in whole seconds (0 or less: cutting is off).
    # @return [Integer]
    def self.cut_after
      Config.get("steer.cut_after").to_i
    end

    # +clock+: monotonic seconds; +controller+: the running turn's cancel
    # controller (nil between turns), read only when a cut is due.
    def initialize(clock:, controller:)
      # What the running generation streams: whether a steer may cut it.
      @phase = GenerationPhase.new(clock: clock)
      # A message that may cut it but came too early: it cuts later.
      @waiting = WaitingSteer.new
      @controller = controller
    end

    # A message for the running turn from +source+ (Steer.source_for_client:
    # nil for the user, "chi_send", "parent_agent") cuts the streaming
    # generation when it has streamed only thinking for steer.cut_after
    # seconds (GenerationPhase): the loops' cut path (CutPolicy) then starts
    # the step again with the message, no nudge, no retry spent. Too early,
    # the message waits (WaitingSteer) and cuts once the thinking passes it
    # (#recheck, on each thinking chunk), unless a boundary hands it to the
    # model first. A plugin's message never cuts, nor an unknown client's
    # (automatic:<id>).
    # Call it after the message is queued, with the #input_epoch read
    # before queueing it. Outside any lock; a cut that lands just after the
    # generation ended is harmless (the loop re-asks).
    # @return [Symbol] :now (a generation was cut now), :waits (the message
    #   waits for the thinking to pass steer.cut_after), or :off (cutting
    #   off for this source: a plugin, no turn, cut_after 0, a generation
    #   that isn't thinking-only, or a drain already took the message)
    def cut_for_steer(source, epoch: nil)
      return :off unless Steer.cuts?(source)

      after = self.class.cut_after
      return :off unless after.positive?

      ctrl = @controller.call
      return :off unless ctrl
      return cut!(ctrl, source.to_s) ? :now : :off if @phase.cuttable?(after)

      waited = @waiting.wait!(source, epoch: epoch)
      Log.info(:turn, "steer_cut_waits", source: source.to_s) if waited
      waited ? :waits : :off
    rescue StandardError
      :off
    end

    # The drains that took input so far (WaitingSteer#epoch): read it before
    # queueing a message for #cut_for_steer.
    def input_epoch
      @waiting.epoch
    end

    # The turn's stream: the generation's phase follows it, and a thinking
    # chunk rechecks a waiting message. +progress+: a chunk's lanes
    # (.lanes), read from it when not given.
    def observe(event, progress = nil)
      case event[:type]
      when :generation_started then @phase.started!
      when :generation_chunk
        progress ||= self.class.lanes(event)
        @phase.chunk!(**progress, tool_call: event[:tool_call])
        recheck unless progress[:thinking].empty?
      when :generation_retrying then @phase.retrying!
      when :generation_completed, :generation_cancelled then @phase.finished!
      end
    end

    # The turn's input went to the model: a message that waited to cut is in.
    def delivered!
      @waiting.delivered!
    end

    # The turn ended: no generation, nothing waiting.
    def finished!
      @phase.finished!
      @waiting.clear!
    end

    private

    # A thinking chunk streamed: a waiting message cuts once the thinking
    # passes steer.cut_after.
    def recheck
      return unless @waiting.waiting?

      after = self.class.cut_after
      return unless after.positive? && @phase.cuttable?(after)

      source = @waiting.take
      ctrl = @controller.call
      cut!(ctrl, source, waited: true) if source && ctrl
    rescue StandardError
      nil
    end

    def cut!(ctrl, source, waited: false)
      age = @phase.age
      cut = ctrl.cancel_generation!(:steer, { by: "steer", steer: true, source: source, reason: "a new message" })
      if cut
        @waiting.clear!
        fields = { source: source, age: age&.round(1) }
        fields[:waited] = true if waited
        Log.info(:turn, "steer_cut", **fields)
      end
      cut
    end
  end
end
