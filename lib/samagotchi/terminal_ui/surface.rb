# frozen_string_literal: true

module Samagotchi
  class TerminalUI
    # Where a terminal UI draws. Two kinds of output:
    #
    # - +commit(text)+: permanent output (may hold several lines). It goes to
    #   the scrollback and is never redrawn.
    # - Slots: named groups of rows that the UI replaces as its state changes.
    #   +set_slot(name, rows)+ shows +rows+ in the slot, replacing what it
    #   held, and +clear_slot(name)+ removes them. clear_slot returns whether
    #   it erased anything.
    #
    # The slots, top down around the prompt: +activity+ (spinner, thinking
    # preview), +editor+ (the prompt), +status+, +notes+ (question choices),
    # +hints+. An implementation without a live region (LegacySurface) may
    # print a slot's rows as plain output instead, so the rows stay on screen.
    #
    # Implementations include this module for the slot names.
    module Surface
      SLOTS = %i[activity editor status notes hints].freeze

      private

      def check_slot!(name)
        raise ArgumentError, "unknown slot #{name.inspect} (slots: #{SLOTS.join(", ")})" unless SLOTS.include?(name)
      end
    end
  end
end
