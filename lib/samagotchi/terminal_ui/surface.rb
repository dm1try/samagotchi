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
    #   it erased anything. +set_slots(name => rows, ...)+ changes several
    #   at once (empty rows clear a slot); a live region draws them as one
    #   frame.
    #
    # The slots, top down around the prompt: +activity+ (spinner, thinking
    # preview), +editor+ (the prompt), +status+, +notes+ (question choices),
    # +hints+. An implementation without a live region (LegacySurface) may
    # print a slot's rows as plain output instead, so the rows stay on screen.
    #
    # Instead of rows, a slot may hold content that lays itself out: anything
    # with +fit(width:, height:)+ -> rows (height nil: no limit). A live
    # region fits it at every frame into the rows the slots above it leave
    # (a question's choices on a short terminal); the others fit it once.
    #
    # Implementations include this module for the slot names.
    module Surface
      SLOTS = %i[activity editor status notes hints].freeze

      def set_slots(**rows_by_slot)
        rows_by_slot.each { |name, rows| set_slot(name, rows) }
        nil
      end

      private

      # @return [Array<String>] +rows+, or the rows fitted content gives
      def lay_out(rows, width:, height: nil)
        rows.respond_to?(:fit) ? Array(rows.fit(width: width, height: height)) : Array(rows)
      end

      def check_slot!(name)
        raise ArgumentError, "unknown slot #{name.inspect} (slots: #{SLOTS.join(", ")})" unless SLOTS.include?(name)
      end
    end
  end
end
