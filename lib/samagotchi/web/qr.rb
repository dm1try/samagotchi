# frozen_string_literal: true

require "rqrcode_core"

module Samagotchi
  module Web
    # A QR code for the terminal: two module rows per line in half blocks
    # (▀ ▄ █), black on white whatever the terminal's theme, so a phone's
    # camera reads it on a dark terminal too.
    module QR
      # Modules of white around the code. The standard asks for 4; the
      # white background makes 2 enough for a phone at a screen.
      QUIET = 2
      COLORS = "\e[30;107m"
      RESET = "\e[0m"

      module_function

      # @return [Array<String>] the lines, colors included
      def lines(text, quiet: QUIET, color: true)
        rows = matrix(text, quiet: quiet)
        rows << Array.new(rows.first.size, false) if rows.size.odd?
        rows.each_slice(2).map do |top, bottom|
          line = top.zip(bottom).map do |t, b|
            if t
              b ? "█" : "▀"
            else
              (b ? "▄" : " ")
            end
          end.join
          color ? "#{COLORS}#{line}#{RESET}" : line
        end
      end

      # Dark modules as true, the quiet zone around them.
      # Level L: the code is read off a screen, never damaged, and stays small.
      def matrix(text, quiet: QUIET)
        code = RQRCodeCore::QRCode.new(text, level: :l)
        size = code.module_count
        blank = Array.new(size + (2 * quiet), false)
        body = Array.new(size) { |r| Array.new(quiet, false) + Array.new(size) { |c| code.checked?(r, c) } + Array.new(quiet, false) }
        Array.new(quiet) { blank.dup } + body + Array.new(quiet) { blank.dup }
      end
    end
  end
end
