# frozen_string_literal: true

module Samagotchi
  # The words a participant is refused with, one per condition, wherever
  # it is met: chi web's routes, the Bridge, the worker, and the
  # SessionAccess errors a chi --remote client raises for the same codes.
  # No requires, so any file can use it.
  module ParticipantMessages
    # 403 not_permitted: a route, a command or a shell line only the owner may use.
    NOT_PERMITTED = "a participant can't do that: only the session's owner can"
    # 429 too_many_turns: their running turn and its queue are full.
    TOO_MANY_TURNS = "this participant has too many turns waiting: wait for one to finish"
    # 429 cap_reached: their grant spent its cap.
    CAP_REACHED = "this participant's spending cap is reached: ask the session's owner to raise it"
    # Their turn failed (a wait's error, a failed turn's no_reply): never
    # the exception's words or the failure summary, which may name a path.
    TURN_FAILED = "this turn failed: the session's owner can see why"
  end
end
