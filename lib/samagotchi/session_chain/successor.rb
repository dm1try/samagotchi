# frozen_string_literal: true

require_relative "../continue_intent"
require_relative "links"

module Samagotchi
  module SessionChain
    # The one answer to "is this link continued, and by whom": +id+ the
    # successor's, +via+ how it was found — :next (a saved session continues
    # the link: Links#next_of, raw), :anchor (a schedule's pruned anchor: the
    # schedule's head, Links#anchor_forward) or :in_flight (a continue of the
    # link holds its transition lock and names its successor, not saved yet
    # or just saved: ContinueIntent.in_flight).
    #
    # Who asks what: SessionAccess::Local#continued_as (peer say/pair, a
    # context push: .of, in flight only while the lock is held),
    # SessionContinue's check (.of, no in-flight: it holds the lock itself),
    # follow_guard (.of without the anchor while it holds the lock, as it
    # always asked; .in_flight when it can't), SessionInbox::Head#continuing
    # and Schedules#continuing_reason (.in_flight alone: their walk already
    # crossed the saved links).
    Successor = Data.define(:id, :via) do
      def in_flight? = via == :in_flight

      # The successor of +id+, or nil: a saved one first (one Session.list,
      # Links), then, with +anchor+, a pruned anchor's head, then, with
      # +in_flight+, a continue in flight. No archive check: a caller that
      # only asks of archived links checks that first (it lists nothing).
      # @return [Successor, nil]
      def self.of(id, state_dir:, in_flight: false, anchor: true)
        return nil unless Session.valid_id?(id)

        links = Links.new(state_dir: state_dir)
        if (following = links.next_of(id))
          return new(id: following, via: :next)
        end
        if anchor && (head = links.anchor_forward(id))
          return new(id: head, via: :anchor)
        end

        in_flight ? self.in_flight(id, state_dir: state_dir) : nil
      end

      # A continue of +id+ in flight, its successor (ContinueIntent.in_flight:
      # the intent written, the lock held), or nil. Lists nothing.
      # @return [Successor, nil]
      def self.in_flight(id, state_dir:)
        successor = ContinueIntent.in_flight(id, state_dir: state_dir)
        successor && new(id: successor, via: :in_flight)
      end
    end

    # A link continued by another session (or being continued now): one
    # refusal owning the words. Callers add what to do next as a tail
    # (": say it there", "; send again in a moment").
    # +session_id+ nil names "this session" (a peer's line, which carries no
    # id: the installed chi-peer skills look for "this session was continued
    # as <new id>").
    class Continued < StandardError
      attr_reader :session_id, :successor_id

      # @param in_flight [Boolean] the successor is not saved yet ("is being
      #   continued as")
      def initialize(session_id, successor_id, in_flight: false)
        @session_id = session_id
        @successor_id = successor_id
        @in_flight = in_flight
        subject = session_id ? "session #{session_id.to_s[0, 8]}" : "this session"
        super("#{subject} #{in_flight ? "is being" : "was"} continued as #{successor_id}")
      end

      def in_flight? = @in_flight

      # The refusal for +successor+ (a Successor).
      def self.for(session_id, successor) = new(session_id, successor.id, in_flight: successor.in_flight?)
    end
  end
end
