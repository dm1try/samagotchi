# frozen_string_literal: true

require_relative "client_id"

module Samagotchi
  # Whether a turn's sender is a visitor in a session: an agent's
  # (agent:<name>) that is not the session's driver (Session#driver). A
  # visitor's turn opens with one header line naming it (Steer::OPENER_HEADERS),
  # counts toward session.max_wakes (Worker#run_prompt) and is not the
  # owner's prompt (OwnerPrompt). The driver's turns are as chi send's
  # were. No Engine: the Worker and the turn stages both ask it.
  module Visitor
    # The refused visitor turn's cancel_reason (TurnCheckpoint.record_refused):
    # a code, whose sentence is ParentReport::REFUSED_LINES'.
    CAP_REASON = "max_wakes"

    module_function

    # @param session [Session, nil] the session the turn runs in
    def of?(client_id, session)
      ClientId.agent?(client_id) && client_id.to_s != driver_of(session)
    end

    # Whether +client_id+ is the session's driver.
    def driver?(client_id, session)
      ClientId.agent?(client_id) && client_id.to_s == driver_of(session)
    end

    def driver_of(session)
      session.respond_to?(:driver) ? session.driver.to_s : ""
    end
    private_class_method :driver_of
  end
end
