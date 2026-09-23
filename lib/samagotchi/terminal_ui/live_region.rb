# frozen_string_literal: true

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

      # Hand Reline its own drawing back, then close the surface.
      def close(surface)
        RelineSeam.detach(surface)
        surface.close
      end

      def available?(out:, input:, env:)
        out.tty? && input.tty? && env["TERM"] != "dumb" && RelineSeam.supported?
      end
    end
  end
end
