# frozen_string_literal: true

require_relative "../degrade"

module Samagotchi
  class Worker
    # A failed block's fix (Engine::BlockFixPart) lands on the loop, between
    # turns: in each pass that runs the queued commands and absorbs the
    # notes, after the commands and before the notes and the next prompt, so
    # a fix ready as a turn ends is in the conversation the next queued turn
    # sends; one that isn't lands when that turn ends. Reads @engine.
    module BlockFixesPart
      private

      # The fixes waiting, written into the conversation and saved.
      def apply_block_fixes
        applied = Degrade.call(:worker, "block_fix_apply_failed", fallback: 0) { @engine.apply_block_fixes }
        save_or_log(:block_fix) { save_session } if applied.positive?
      end
    end
  end
end
