# frozen_string_literal: true

module Samagotchi
  module Tools
    # What list_sessions and send_note know about the asking session: its
    # id (left out of the list, the note's sender), its folder and where
    # sessions live. Engine hands KernelLoop one that follows its current
    # session.
    Peers = Struct.new(:session_id, :cwd, :state_dir, keyword_init: true)
  end
end
