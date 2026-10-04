# frozen_string_literal: true

require "reline"

module Samagotchi
  class TerminalUI
    # Prepended to Reline::LineEditor: while a Screen is attached, Reline
    # keeps doing all the input work (keys, history, completion dialogs,
    # multiline, paste) but draws nothing itself. Its rendered rows go to the
    # Screen's editor slot, and a finished prompt goes to scrollback through
    # the Screen. With no Screen attached every method is Reline's own.
    #
    # This overrides private methods of reline 0.6.x (the Gemfile pins it).
    # .supported? checks that they are all still there; without them attached
    # mode falls back to plain output. What each override relies on:
    # - render_differential(lines, cursor_x, cursor_y): called by #render
    #   with the rows it laid out; the seam hands them to the Screen and keeps
    #   @rendered_screen as if Reline had drawn them.
    # - reset: asks the terminal for the cursor row (base_y), which decides
    #   whether a dialog opens below the prompt. The region's editor rows
    #   start at 0.
    # - screen_height: the rows Reline may draw in, cut to the Screen's
    #   editor budget so the region fits (Reline scrolls the input inside it).
    #   Overriding the method, not @screen_size, survives reset and resizes.
    # - update(key): every key a read takes, for the key handler.
    # - render_finished (Enter), handle_interrupted (Ctrl-C), finalize (every
    #   read, including one dropped by Thread#raise), ed_clear_screen and its
    #   alias clear_screen (Ctrl-L), handle_resized (SIGWINCH, SIGCONT).
    module RelineSeam
      # Reline's methods the seam overrides or calls, with their arities.
      METHODS = { reset: -1, finalize: 0, render_finished: 0, screen_height: 0, screen_width: 0,
                  prompt_list: 0, modified_lines: 0, clear_dialogs: 0, scroll_into_view: 0, render: 0,
                  render_differential: 3, handle_interrupted: 0, handle_resized: 0,
                  clear_rendered_screen_cache: 0, ed_clear_screen: 1, clear_screen: 1,
                  split_line_by_width: -3, update: 1 }.freeze

      class << self
        # @return [Screen, nil] where Reline draws, nil for Reline's own drawing
        attr_reader :screen

        # Asked first on Ctrl-C during a read, with or without a screen: a
        # truthy answer means it handled the key (the REPL cancelled a running
        # turn) and the read goes on with the typed text as it is.
        # @return [#call, nil]
        attr_accessor :interrupt_handler

        # Called with no arguments for each key a read takes (typing is
        # activity for the REPL's idle clock).
        # @return [#call, nil]
        attr_accessor :key_handler

        # @return [Boolean] a Reline read is open (it owns stdin)
        def reading? = @reading == true

        # Run a read (on this thread) whose submitted line leaves nothing in
        # the scrollback: the answer to a question, which commits its own
        # summary line instead.
        def without_echo
          was = Thread.current[:samagotchi_reline_no_echo]
          Thread.current[:samagotchi_reline_no_echo] = true
          yield
        ensure
          Thread.current[:samagotchi_reline_no_echo] = was
        end

        # @api private
        attr_writer :reading

        # Monotonic time a read's cursor query went out (#reset) when the read
        # was stopped before Reline took the reply: the reply is still on its
        # way, and LiveRegion.close waits for it. nil with none.
        # @return [Float, nil]
        attr_accessor :unanswered_query_at

        # @return [Boolean] this Reline has every method the seam relies on
        def supported?
          defined?(Reline::LineEditor::RenderedScreen) &&
            (%i[base_y lines cursor_y] - Reline::LineEditor::RenderedScreen.members).empty? &&
            METHODS.all? { |name, arity| reline_method(name)&.arity == arity }
        end

        # Reline draws into +screen+ from its next render on.
        def attach(screen)
          # Measuring a character like … or │ makes Reline print one and ask
          # the terminal where the cursor went, the first time only. Do it
          # now, before the Screen measures rows from other threads while a
          # read owns stdin.
          Reline.ambiguous_width
          install
          @screen = screen
        end

        # Put the seam in Reline without a screen: Reline draws as usual, and
        # reading? and the interrupt handler work.
        def install
          Reline::LineEditor.prepend(self) unless Reline::LineEditor.include?(self)
        end

        def detach(screen)
          @screen = nil if @screen.equal?(screen)
        end

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

      def reset(...)
        # Reline's reset asks the terminal for the cursor row and waits for
        # the reply: a Stop raised meanwhile leaves this set.
        RelineSeam.unanswered_query_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        super
        RelineSeam.unanswered_query_at = nil
        RelineSeam.reading = true
        @rendered_screen.base_y = 0 if RelineSeam.screen
      end

      def update(key)
        RelineSeam.key_handler&.call
        super
      end

      def screen_height
        screen = RelineSeam.screen
        screen ? [super, screen.editor_budget].min : super
      end

      def render_finished
        screen = RelineSeam.screen
        return super unless screen

        screen.finish_editor(Thread.current[:samagotchi_reline_no_echo] ? nil : seam_final_lines)
        clear_rendered_screen_cache
      end

      # A read that ends without render_finished (dropped by Thread#raise,
      # or an I/O error) leaves its prompt in the region: take it out.
      def finalize
        screen = RelineSeam.screen
        if screen && !@rendered_screen.lines.empty?
          screen.finish_editor
          clear_rendered_screen_cache
        end
        RelineSeam.reading = false
        super
      end

      private

      def render_differential(new_lines, cursor_x, cursor_y)
        screen = RelineSeam.screen
        return super unless screen

        cursor_y = cursor_y.clamp(0, [screen_height - 1, 0].max)
        screen.draw_editor(new_lines, cursor_x, cursor_y)
        @rendered_screen.lines = new_lines
        @rendered_screen.cursor_y = cursor_y
      end

      # Ctrl-C: the interrupt handler's if it takes it. Otherwise the typed
      # text stays in scrollback with ^C, then Reline's own handling of the
      # trap it replaced (raise Interrupt by default).
      def handle_interrupted
        return unless @interrupted

        if RelineSeam.interrupt_handler&.call
          @interrupted = false
          return
        end
        screen = RelineSeam.screen
        return super unless screen

        @interrupted = false
        clear_dialogs
        screen.finish_editor(seam_final_lines.tap { |lines| lines[-1] = "#{lines[-1]}^C" })
        clear_rendered_screen_cache
        case @old_trap
        when "DEFAULT", "SYSTEM_DEFAULT" then raise Interrupt
        when "IGNORE" then nil
        when "EXIT" then exit
        else @old_trap.call if @old_trap.respond_to?(:call)
        end
      end

      def handle_resized
        screen = RelineSeam.screen
        return super unless screen
        return unless @resized

        @screen_size = Reline::IOGate.get_screen_size
        @resized = false
        scroll_into_view
        clear_rendered_screen_cache
        render
      end

      def ed_clear_screen(key)
        screen = RelineSeam.screen
        return super unless screen

        screen.clear_screen
        @screen_size = Reline::IOGate.get_screen_size
        clear_rendered_screen_cache
      end

      # Reline's alias still points at its own ed_clear_screen.
      def clear_screen(key) = ed_clear_screen(key)

      # The prompt and the text as render_finished writes them: one line per
      # input line, with a trailing space when a line fills the width exactly.
      def seam_final_lines
        Array.new(@buffer_of_lines.size) do |i|
          line = Reline::Unicode.strip_non_printing_start_end(prompt_list[i]) + modified_lines[i]
          split_line_by_width(line, screen_width).last.empty? ? "#{line} " : line
        end
      end
    end
  end
end
