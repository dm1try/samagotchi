# frozen_string_literal: true

require "reline"

require_relative "line_reader"

module Samagotchi
  class TerminalUI
    # Prepended to Reline::LineEditor: the first ↑ of a history walk at the
    # main prompt runs the refresh first, so lines other processes (the web,
    # another TUI) added to the shared history since the prompt opened are
    # in the ring it walks. Set per read with .with_refresh; any other read
    # (a question, a continue prompt) gets Reline's own ↑.
    #
    # Kept apart from RelineSeam, whose supported? is all-or-nothing: drift
    # here only turns this hook off. It overrides two private methods of
    # reline 0.6.x (the Gemfile pins it), both with Reline's signature
    # (key, arg: 1), which Reline's dispatch looks at for an arg: keyword:
    # - ed_prev_history: ↑, Ctrl-P, vi command k and -.
    # - previous_history: its alias, which inputrc's previous-history binds.
    # It reads two ivars: @history_pointer (nil while not walking the
    # history) and @line_index (the cursor's line in a multi-line buffer;
    # ↑ off line 0 only moves up a line). Without them it is plain Reline.
    # A failing refresh leaves plain ↑; LineReader's Reprompt and Stop go on.
    module RelineHistoryHook
      # Reline's methods the hook overrides, with their arities.
      METHODS = { ed_prev_history: -2, previous_history: -2 }.freeze

      class << self
        # @return [Boolean] this Reline has every method the hook overrides
        def supported?
          METHODS.all? { |name, arity| reline_method(name)&.arity == arity }
        end

        def install
          Reline::LineEditor.prepend(self) unless Reline::LineEditor.include?(self)
        end

        # Run a read (on this thread) whose first ↑ of a walk calls
        # +refresh+ first.
        # @param refresh [#call, nil]
        def with_refresh(refresh)
          was = Thread.current[:samagotchi_reline_history_refresh]
          Thread.current[:samagotchi_reline_history_refresh] = refresh
          yield
        ensure
          Thread.current[:samagotchi_reline_history_refresh] = was
        end

        # @return [#call, nil] the refresh of the read on this thread
        def refresh = Thread.current[:samagotchi_reline_history_refresh]

        private

        # Reline's own implementation, past this module once it is prepended.
        def reline_method(name)
          method = Reline::LineEditor.instance_method(name)
          method = method.super_method while method&.owner == self
          method
        rescue NameError
          nil
        end
      end

      private

      def ed_prev_history(key, arg: 1)
        refresh_history_before_walk
        super
      end

      def previous_history(key, arg: 1)
        refresh_history_before_walk
        super
      end

      # Only at the start of a walk: appending to Reline::HISTORY mid-walk
      # would shift what the pointer means.
      def refresh_history_before_walk
        refresh = RelineHistoryHook.refresh
        return unless refresh
        return unless instance_variable_defined?(:@history_pointer) && instance_variable_defined?(:@line_index)
        return unless @history_pointer.nil? && @line_index.zero?

        refresh.call
      rescue LineReader::Reprompt, LineReader::Stop
        raise
      rescue StandardError
        nil
      end
    end
  end
end
