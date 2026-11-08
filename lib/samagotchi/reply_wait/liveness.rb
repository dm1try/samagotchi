# frozen_string_literal: true

require_relative "../session"
require_relative "../worker_link"

module Samagotchi
  module ReplyWait
    # Who runs the session, as one look of a wait reads it: one owner lock
    # read and one WorkerLink resolve on it. Two readers on purpose:
    # #owner? (any kind, a one-turn chi run's too: its turn is alive) for
    # whether the worker is gone, #worker_owned? (a worker's lock) for
    # whether a question waits for an answer (a one-turn run's is answered
    # there; a dead worker's waits for no one).
    class Liveness
      def initialize(id, state_dir:)
        @id = id
        @state_dir = state_dir
      end

      # The lock's holder (SessionManager.session_owner).
      # @return [OwnerLock::Owner, nil]
      def owner
        return @owner if defined?(@owner)

        @owner = SessionManager.session_owner(@id, state_dir: @state_dir)
      end

      def owner? = !owner.nil?

      def worker_owned?
        return @worker_owned if defined?(@worker_owned)

        @worker_owned = WorkerLink.resolve(Session.session_dir(@id, state_dir: @state_dir), unlink: false,
                                                           owner: owner).worker_owned?
      end
    end
  end
end
