# frozen_string_literal: true

require_relative "formatting"
require_relative "event_renderer"

module Samagotchi
  class TerminalUI
    # What the REPL prints between turns: cards and plugins' notices shown
    # outside a turn, anytime commands' output, plugins' init lines and load
    # warnings, and a recap written while idle.
    #
    # They are announced on other threads (the Engine's observers, the idle
    # scheduler, an anytime command's own), where they are only kept; the
    # main thread prints them at the open prompt (#flush_recap,
    # #flush_cards), after the command that showed them. One that comes
    # while a turn runs prints at once (above the live region) where the
    # turn wouldn't print it itself.
    class BetweenTurns
      include Formatting

      # A plugin's init task and a load warning: shown between turns too.
      INIT_EVENTS = %i[plugin_init_started plugin_init_finished guardrail_warning].freeze

      # @param surface [Surface] where lines print (swapped with #surface=)
      # @param view [AttachedView] turns the activity row for init tasks
      # @param renderer [EventRenderer] draws cards
      # @param turn_running [#call] whether a turn runs now
      # @param quiet [Boolean] a --non-interactive run: no init lines
      def initialize(surface:, view:, renderer:, turn_running:, quiet: false)
        @surface = surface
        @view = view
        @renderer = renderer
        @turn_running = turn_running
        @quiet = quiet
        @cards = Queue.new
        @recap = nil
      end

      attr_writer :surface

      # The Engine's observer for cards, notices and init events (any
      # thread). A card or a plugin's notice shown outside a turn is kept
      # for the next flush; one shown during a turn is a turn event, the
      # turn's sink prints it where it happens (EventRenderer).
      #
      # An anytime command's (event[:anytime]) print as it shows them: on
      # the main thread (the command runs at the prompt) or beside a running
      # turn, else at the next flush.
      #
      # A plugin's init task (chi.init) turns the activity row while it runs
      # and prints a line when it is done; a load warning announced before
      # the first turn, one. Beside a running turn they print at once.
      def observe(event)
        if INIT_EVENTS.include?(event[:type])
          return if @quiet
          return @view.init_started(event) if event[:type] == :plugin_init_started

          @view.init_finished(event) if event[:type] == :plugin_init_finished
          return show(event) if turn_running?

          return @cards << event
        end
        return unless (event[:type] == :card && !event[:in_turn]) || (event[:type] == :hook_notice && event[:between_turns])
        return show(event) if event[:anytime] && (Thread.current == Thread.main || turn_running?)

        @cards << event
      end

      # Keep an item for the next flush (any thread).
      def keep(item)
        @cards << item
      end

      # An anytime command's output: beside a running turn at once, else at
      # the next flush.
      def show_or_keep(item)
        turn_running? ? show(item) : keep(item)
      end

      # The Engine's observer for :recap_ready (the idle scheduler's thread):
      # kept for #flush_recap. One collected just as a turn started describes
      # the chat before it, and is dropped.
      def take_recap(event)
        return unless event[:type] == :recap_ready
        return if event[:recap].to_s.strip.empty? || turn_running?

        @recap = event[:recap].to_s
      end

      # Print a recap written while idle (main thread, at the open prompt).
      def flush_recap
        recap = @recap
        return unless recap

        @recap = nil
        @surface.commit(recap_block(recap))
      end

      # Print the cards, notices and anytime commands' output kept since the
      # last flush (main thread). A card replaced later in the same batch
      # (the same id: btw's "thinking…", then its answer) prints once, as its
      # last.
      def flush_cards
        items = []
        loop { items << @cards.pop(true) }
      rescue ThreadError
        items.each_with_index do |item, index|
          replaced = item[:type] == :card && items.drop(index + 1).any? { |later| later[:type] == :card && later[:id] == item[:id] }
          show(item) unless replaced
        end
        nil
      end

      # A card, a notice, an anytime command's output (:command_output), a
      # plugin init task's done line or a load warning.
      def show(item)
        case item[:type]
        when :card then @renderer.render_card(item)
        when :command_output then @surface.commit(item[:text])
        when :guardrail_warning then @surface.commit(EventRenderer.load_warning_line(item))
        when :plugin_init_finished
          line = EventRenderer.init_line(item)
          @surface.commit(line) if line
        else @surface.commit(EventRenderer.hook_notice_line(item))
        end
      end

      private

      def turn_running? = @turn_running.call
    end
  end
end
