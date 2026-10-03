# frozen_string_literal: true

require "io/console"
require_relative "screen"
require_relative "reline_seam"

module Samagotchi
  class TerminalUI
    # Opens and closes a live region: a Screen with Reline drawing into it
    # through RelineSeam. The REPL and attached mode both use one when the
    # terminal can show it, and fall back to their own plain output otherwise.
    module LiveRegion
      module_function

      # @return [Screen, nil] a started Screen with Reline attached, or nil
      #   when the terminal can't show a live region (output or input not a
      #   terminal, TERM=dumb, or a Reline the seam doesn't support)
      def open(out: $stdout, input: $stdin, env: ENV)
        return unless available?(out: out, input: input, env: env)

        screen = Screen.new(out: out).start
        RelineSeam.attach(screen)
        screen
      end

      # How long #drain_input waits for input still on its way.
      DRAIN_WINDOW = 0.05
      # How long Reline waits for the reply to its cursor query (Reline::ANSI#cursor_pos).
      CURSOR_REPLY_WAIT = 0.5
      CURSOR_REPLY = /\e\[\d+;\d+R/

      # Hand Reline its own drawing back, close the surface, then drop the
      # input nobody read (#drain_input).
      def close(surface, input: $stdin)
        RelineSeam.detach(surface)
        surface.close
        query_at = RelineSeam.unanswered_query_at
        RelineSeam.unanswered_query_at = nil
        drain_input(input, query_at: query_at) if surface.is_a?(Screen)
      end

      # Reline asks the terminal for the cursor row (ESC[6n) as each read
      # starts; the reply to one cut short at exit, read by nobody, would
      # land at the shell's prompt. What came, or comes within DRAIN_WINDOW,
      # is read and dropped (keys typed in that moment too), in raw mode, so
      # a reply with no newline is readable. With a query left unanswered
      # (RelineSeam.unanswered_query_at), until its reply, up to as long as
      # Reline would have waited for it.
      def drain_input(input, query_at: nil)
        return unless input.is_a?(IO) && input.tty?

        now = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        deadline = now.call + DRAIN_WINDOW
        deadline = [deadline, query_at + CURSOR_REPLY_WAIT].max if query_at
        dropped = +""
        input.raw do
          while (left = deadline - now.call).positive? && input.wait_readable(left)
            read = input.read_nonblock(1024, exception: false)
            break if read.nil?

            dropped << read if read.is_a?(String)
            # The reply came: no need to wait out the rest.
            deadline = [now.call + DRAIN_WINDOW, deadline].min if query_at && dropped.match?(CURSOR_REPLY)
          end
        end
      rescue IOError, SystemCallError
        nil
      end

      def available?(out:, input:, env:)
        out.tty? && input.tty? && env["TERM"] != "dumb" && RelineSeam.supported?
      end
    end
  end
end
