# frozen_string_literal: true

require_relative "../worker_link"
require_relative "../worker_presence"
require_relative "../session_lifecycle"

module Samagotchi
  module SessionLifecycle
    # One read of a session's lifecycle: the state (one of STATES), the
    # facts it was derived from, and the successor of a continue in flight.
    # @!attribute state [Symbol] one of STATES
    # @!attribute presence [WorkerPresence] read with its link (:look)
    # @!attribute continuing [String, nil] ContinueIntent.in_flight's
    #   successor: a fact, not a state (only a send's or a schedule's link
    #   resolution reads it)
    # @!attribute transitioning [Boolean] a transition holds the session's
    #   transition lock now (SessionTransition.held?): a fact, not a state,
    #   orthogonal to them all; a :shared delivery row answers TRANSITIONING's
    #   cell then (SessionLifecycle.allowed's transitioning:)
    Reading = Data.define(:state, :presence, :continuing, :transitioning) do
      # @param presence [WorkerPresence] with its link read
      # @param continuing [String, nil]
      # @param transitioning [Boolean]
      # @return [Reading]
      def self.derive(presence, continuing: nil, transitioning: false)
        new(state: state_of(presence), presence: presence, continuing: continuing, transitioning: transitioning)
      end

      # The first of STATES whose facts hold. A lock held by someone that is
      # neither a one-turn run nor a deleter, without a worker's link (a lock
      # record still blank: WorkerLink reads it Starting), is booting.
      # @return [Symbol]
      def self.state_of(presence)
        return :absent unless presence.exists?

        owner = presence.owner
        return :tui_owned if owner&.tui?
        return :deleting if owner&.deleting?
        return :stopping if owner&.worker? && presence.stop_marked?
        return link_state(presence.link) if owner

        unowned_state(presence)
      end

      def self.link_state(link)
        case link
        when WorkerLink::Skew then :skew
        when WorkerLink::Leaving then :leaving
        when WorkerLink::Live then :live
        when WorkerLink::Starting then link.stuck ? :booting_stuck : :booting
        else :booting
        end
      end
      private_class_method :link_state

      def self.unowned_state(presence)
        stop = presence.stop_marked?
        start = presence.starting?
        return start ? :stopped_starting : :stopped if stop
        return start ? :archived_starting : :archived if presence.archived?

        start ? :starting : :idle
      end
      private_class_method :unowned_state

      def facts = presence
      def continuing? = !continuing.nil?
      def transitioning? = transitioning == true
    end
  end
end
