# frozen_string_literal: true

module Samagotchi
  # Where a card or a notice goes, by what this thread is doing (Engine#show_card,
  # HookRoutes#notify, HookRoutes#guardrail_notify):
  #
  # 1. the plugins load (ExtensionLoad#loading?): held, announced after the load
  #    (Engine#announce_load_events!);
  # 2. an anytime command's thread (Engine#running_anytime): announced at once,
  #    marked anytime: true;
  # 3. a plugin's init task (chi.init): announced, never a running turn's event;
  # 4. a running turn: the turn's event (its sink and the observers);
  # 5. else announced, or held for Engine#holding_announcements' caller.
  #
  # #route takes all five; #route_by_turn only 4 and 5 (a guardrails line).
  # Each caller says what the event is marked with on each route (CARD_MARKS,
  # NOTICE_MARKS). What it needs from the Engine comes through lookups, called
  # at use.
  class EventRoutes
    # A card says whether it came in a turn (in_turn:); a held one, true.
    CARD_MARKS = { held: { in_turn: true }.freeze, in_turn: { in_turn: true }.freeze,
                   between: { in_turn: false }.freeze }.freeze
    # A notice is marked only outside a turn (between_turns: true).
    NOTICE_MARKS = { held: {}.freeze, in_turn: {}.freeze, between: { between_turns: true }.freeze }.freeze

    # @param extension_load   [#call] → ExtensionLoad (#loading?, #hold)
    # @param in_turn_sink     [#call] → [Boolean, sink] (TurnState#in_turn_sink)
    # @param anytime_thread   [#call] → whether this thread runs an anytime command
    # @param init_task        [#call] → the init task running on this thread, nil
    # @param announce         [#call] (event) → announces an event
    # @param announce_anytime [#call] (event) → announces an anytime command's event
    # @param announce_or_hold [#call] (event) → announces it, or holds it for the caller
    # @param emit             [#call] (sink, event) → emits to a turn's sink + observers
    def initialize(extension_load:, in_turn_sink:, anytime_thread:, init_task:, announce:, announce_anytime:,
                   announce_or_hold:, emit:)
      @extension_load = extension_load
      @in_turn_sink = in_turn_sink
      @anytime_thread = anytime_thread
      @init_task = init_task
      @announce = announce
      @announce_anytime = announce_anytime
      @announce_or_hold = announce_or_hold
      @emit = emit
    end

    # Route +event+ by the five routes, first match wins.
    # @param held    [Hash] merged into the event held while the plugins load
    # @param in_turn [Hash] merged into a running turn's event
    # @param between [Hash] merged into an event announced outside a turn (routes 2, 3, 5)
    # @return [Symbol] the route taken: :held, :anytime, :init, :in_turn or :between
    def route(event, held:, in_turn:, between:)
      extension_load = @extension_load.call
      if extension_load.loading?
        extension_load.hold(event.merge(held))
        return :held
      end
      if @anytime_thread.call
        @announce_anytime.call(event.merge(between))
        return :anytime
      end
      if @init_task.call
        @announce.call(event.merge(between))
        return :init
      end
      route_by_turn(event, in_turn: in_turn, between: between)
    end

    # Route +event+ by routes 4 and 5 only: a running turn's event, else
    # announced or held for the caller. Never held while the plugins load,
    # never marked anytime (a guardrails line).
    # @return [Symbol] :in_turn or :between
    def route_by_turn(event, in_turn: {}, between: {})
      running, sink = @in_turn_sink.call
      if running
        @emit.call(sink, event.merge(in_turn))
        :in_turn
      else
        @announce_or_hold.call(event.merge(between))
        :between
      end
    end
  end
end
