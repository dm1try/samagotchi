# frozen_string_literal: true

require_relative "hooks"
require_relative "log"

module Samagotchi
  # The Engine's routes to the UIs for what a hook or a plugin does beyond
  # reading its event (Hooks::Runtime, Plugin::Host): a notice (#notify),
  # a question (#ask_user), stopping the turn or cutting its generation,
  # and a steer; also the guardrails' line after load (#guardrail_notify).
  #
  # What it needs from the Engine comes through lookups, called at use.
  class HookRoutes
    # What a notice may stand in for (#notify's fallback_for:).
    NOTICE_FALLBACKS = %i[display editor].freeze

    # @param extension_load    [#call] → ExtensionLoad (#loading?, #hold)
    # @param in_turn_sink      [#call] → [Boolean, sink] (TurnState#in_turn_sink)
    # @param anytime_thread    [#call] → whether this thread runs an anytime command
    # @param announce_anytime  [#call] (event) → announces an anytime command's event
    # @param init_task         [#call] → the init task running on this thread, nil
    # @param announce          [#call] (event) → announces an event
    # @param announce_or_hold  [#call] (event) → announces it, or holds it for the caller
    # @param emit              [#call] (sink, event) → emits to a turn's sink + observers
    # @param question_desk     [#call] → QuestionDesk
    # @param cancel_controller [#call] → the running turn's CancellationController, nil
    # @param steer             [#call] (text, source) → steers the running turn
    def initialize(extension_load:, in_turn_sink:, anytime_thread:, announce_anytime:, init_task:, announce:,
                   announce_or_hold:, emit:, question_desk:, cancel_controller:, steer:)
      @extension_load = extension_load
      @in_turn_sink = in_turn_sink
      @anytime_thread = anytime_thread
      @announce_anytime = announce_anytime
      @init_task = init_task
      @announce = announce
      @announce_or_hold = announce_or_hold
      @emit = emit
      @question_desk = question_desk
      @cancel_controller = cancel_controller
      @steer = steer
      @unknown_fallbacks = Set.new
    end

    # The things a hook can do beyond reading its event. Each gets the
    # hook's label (event[:hook]) from the registry.
    # @return [Hooks::Runtime]
    def runtime
      Hooks::Runtime.new(
        notify: ->(text:, level:, hook:, fallback_for: nil) { notify(text, level, hook, fallback_for: fallback_for) },
        ask_user: ->(question:, options:, header:, allow_freeform:, hook:) { ask_user(question, options, header, allow_freeform, hook) },
        stop_turn: ->(reason:, hook:) { stop_turn(reason, hook) },
        steer: ->(text:, hook:) { @steer.call(text, source(hook)) },
        stop_generation: ->(reason:, hook:) { stop_generation(reason, hook) }
      )
    end

    # What a steer is attributed to: the bundle of a bundle hook's label
    # ("<file> (bundle <name>)"), the label of any other.
    def source(hook)
      hook.to_s[/\(bundle (.+)\)\z/, 1] || hook.to_s
    end

    # One line to the user (:hook_notice). During a turn it is a turn
    # event: the turn's sink (the REPL) and the observers (bridge, log).
    # Outside one (a plugin's command at the prompt) it is announced with
    # between_turns: true, which every UI shows as cards are shown.
    #
    # +fallback_for+ names what the line stands in for (NOTICE_FALLBACKS):
    # :display, the answer's display (AnswerDisplay), for a UI that doesn't
    # render its links; :editor, a ref the viewer could open in its editor
    # (Web::Capabilities#editor), for a UI or a viewer that can't. A UI that
    # does leaves the line out; the others, the log among them, show it. An
    # unknown value is dropped, so the line shows everywhere.
    # +extra+: more fields for the UIs (a toolkit change's summary).
    def notify(text, level, hook, fallback_for: nil, extra: {})
      level = (level || :info).to_sym
      level = :info unless %i[info warn].include?(level)
      notice = { type: :hook_notice, hook: hook.to_s, text: text.to_s, level: level,
                 fallback_for: notice_fallback(fallback_for, hook) }.compact.merge(extra)
      extension_load = @extension_load.call
      return extension_load.hold(notice) && nil if extension_load.loading?

      in_turn, sink = @in_turn_sink.call
      if @anytime_thread.call
        @announce_anytime.call(notice.merge(between_turns: true))
      elsif @init_task.call
        @announce.call(notice.merge(between_turns: true))
      elsif in_turn
        @emit.call(sink, notice)
      else
        @announce_or_hold.call(notice.merge(between_turns: true))
      end
      nil
    end

    # A guardrails line to the user after load (:guardrail_warning, as the
    # load failures show): a running turn's event, else announced.
    def guardrail_notify(message)
      event = { type: :guardrail_warning, message: message.to_s }
      in_turn, sink = @in_turn_sink.call
      in_turn ? @emit.call(sink, event) : @announce_or_hold.call(event)
      nil
    end

    # A question through the question flow (REPL sync handler, attached TUI,
    # web), single-select, kind "hook". A --non-interactive run has no one
    # to ask: nil at once. Anything but an answer (a sync handler's text, no
    # answer, cancelled) is nil too.
    # @return [Hash, nil] {selected:, freeform:, selected_indices:}
    def ask_user(question, options, header, allow_freeform, hook)
      @question_desk.call.ask_for_hook(question, options, header, allow_freeform, hook)
    end

    # Cancel the running turn (reason :hook), after a notice that says why.
    # The gate denies the rest of a tool batch once the controller is
    # cancelled; the next request ends the turn as :turn_canceled.
    # @return [Boolean] true when a running turn was cancelled now
    def stop_turn(reason, hook)
      ctrl = @cancel_controller.call
      return false unless ctrl && !ctrl.cancelled?

      notify("stopped the turn: #{reason}", :warn, hook)
      ctrl.cancel!(:hook, { by: source(hook), reason: reason.to_s })
    end

    # Cut the streaming generation (reason :hook); the turn goes on and asks
    # the model again (the loops' cut path). No notice: the plugin posts its
    # own. The bundle and +reason+ go to the log and the retry's nudge.
    # @return [Boolean] true when a streaming generation was cut now
    def stop_generation(reason, hook)
      ctrl = @cancel_controller.call
      return false unless ctrl

      ctrl.cancel_generation!(:hook, { by: source(hook), reason: reason.to_s })
    end

    private

    # A known fallback_for (a String is symbolized), else nil; an unknown
    # one is logged once at debug.
    def notice_fallback(value, hook)
      return if value.nil?

      fallback = value.to_s.to_sym
      return fallback if NOTICE_FALLBACKS.include?(fallback)

      Log.debug(:hooks, "notice_unknown_fallback", hook: hook.to_s, value: value.to_s) if @unknown_fallbacks.add?(fallback)
      nil
    end
  end
end
