# frozen_string_literal: true

module Samagotchi
  class Engine
    # Cards and anytime commands: #show_card (routed by EventRoutes), the
    # anytime and session-command thread marks, the anytime threads #shutdown
    # waits for. Reads @event_routes, @anytime_threads under @lifecycle_mutex.
    module CardsPart
      # ── Cards ───────────────────────────────────────────────────────────────

      # Show a card in every UI (docs/plugins.md, Cards): {type: :card, id:,
      # source:, title:, body:, level:, actions: [{label:, command:}], in_turn:}.
      # Where it goes (held while the plugins load, an anytime command's, an
      # init task's, a turn event, else announced) is EventRoutes#route's,
      # marked in_turn: (CARD_MARKS). A card with the id of an earlier one
      # replaces it (btw's "thinking…" → the answer).
      # @param source [String] who shows it (a bundle's name)
      # @param actions [Array<Hash>] {label:, command:}; a command is a line
      #   the session runs, as typed (D3)
      # @return [String] the card's id
      # @raise [ArgumentError] a card without a title, or a bad action
      def show_card(source:, title:, body: "", actions: [], level: :info, id: nil)
        card = Plugin::Card.build(source: source, title: title, body: body, actions: actions, level: level, id: id)
        command = Thread.current[running_command_key]
        card[:command] = command if command
        @event_routes.route(card, **EventRoutes::CARD_MARKS)
        card[:id]
      end

      # Run an anytime command's block (D8): the cards and notices it shows on
      # this thread are announced at once, marked anytime: true, and are
      # never a running turn's events. They belong to the command, not the
      # turn, and a UI shows them after the command's own line (a web
      # command bubble drawn at its command_queued), even mid-turn.
      # @return the block's value
      def running_anytime
        key = :"samagotchi_anytime_#{object_id}"
        outer = Thread.current[key]
        Thread.current[key] = true
        yield
      ensure
        Thread.current[key] = outer
      end

      # Run a session command's dispatch: a card shown on this thread says
      # it's that command's (:card's command:), for a reload that no longer has
      # the command's line above it (Bridge::CardStore). A thread of its own
      # isn't the command, nor a card shown after it.
      # @param name [String] the command, "/short"
      # @return the block's value
      def running_command(name)
        outer = Thread.current[running_command_key]
        Thread.current[running_command_key] = name
        yield
      ensure
        Thread.current[running_command_key] = outer
      end

      # Whether an anytime command (/btw) still runs on its thread.
      def anytime_running?
        @lifecycle_mutex.synchronize { @anytime_threads.any?(&:alive?) }
      end

      # Start an anytime command on its own thread (D8), one #shutdown waits
      # for, so its command_ran is announced before the process leaves.
      # @return [Thread]
      def spawn_anytime(&)
        thread = Thread.new(&)
        @lifecycle_mutex.synchronize do
          @anytime_threads.select!(&:alive?)
          @anytime_threads << thread
        end
        thread
      end

      def anytime_thread? = Thread.current[:"samagotchi_anytime_#{object_id}"] == true
      private :anytime_thread?

      def announce_anytime(event)
        event = event.merge(anytime: true)
        announce(event)
        event
      end
      private :announce_anytime
    end
  end
end
