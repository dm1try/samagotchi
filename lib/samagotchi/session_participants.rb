# frozen_string_literal: true

require_relative "steer"

module Samagotchi
  # Loaded only when a session is read: it brings Grants.
  autoload :Participants, File.expand_path("participants", __dir__)

  # What a session's Engine knows of its participants: participants.json
  # (Participants.read), read at each turn's start (#refresh!), never
  # written here. A session nobody was invited to has no sidecar: one
  # File.exist? per turn. See docs/internals/participants.md (Attribution).
  class SessionParticipants
    # @param state_dir [#call] → the sessions' state dir
    # @param clock [#call] → Time, what "still active" is measured at
    def initialize(state_dir:, clock: -> { Time.now })
      @state_dir = state_dir
      @clock = clock
      @session_id = nil
      @entries = []
    end

    # Reads +session+'s sidecar again.
    # A Verify fresh child reads its parent's (Session#participants_source_id):
    # its requester's grant is there.
    def refresh!(session)
      @session_id = source_id(session)
      @entries = read
      self
    end

    # The time "still active" is measured at (the clock it was given):
    # GuardrailWiring's participant turn mode reads the same, so the prompt
    # line and a turn's mode agree.
    def now = @clock.call

    # Whether anyone is still in the review (Participants::Entry#active?),
    # as of the last #refresh!.
    def active? = @entries.any? { |entry| entry.active?(@clock.call) }

    # The name +author+ ("p:<id>") had when it was invited, nil for none
    # (the owner, or a participant the sidecar doesn't name). A miss reads
    # the sidecar again: someone invited after the turn began. +session+:
    # the session it is asked for, when that may not be the last refreshed
    # (the worker's running save, before the Engine's first turn).
    def name_for(author, session: nil) = entry_for(author, session: session)&.name

    # +author+'s Participants::Entry (their name, cap, grant mode), nil for
    # none; read again on a miss, as #name_for.
    def entry_for(author, session: nil)
      return nil unless Steer.participant_author?(author)

      refresh!(session) if session && source_id(session) != @session_id
      id = Steer.participant_id(author)
      @entries.find { |e| e.id == id } || (@entries = read).find { |e| e.id == id }
    end

    # The system prompt's participants line while anyone is in it (#active?
    # as of the last #refresh!): :pair with an active participant (an older
    # chi's read-only invite is not active), nil with nobody. A Verify fresh
    # child reads its parent's sidecar but has one participant at most, its
    # requester: :pair while their grant is active and the child was saved
    # for their turns to act, nil for the owner's child (no participant ever
    # writes in it).
    def prompt_mode(session)
      active = @entries.select { |entry| entry.active?(@clock.call) }
      return nil if active.empty?

      fresh = session.respond_to?(:verify_fresh) && session.verify_fresh
      return fresh_prompt_mode(fresh, active) if fresh

      :pair
    end

    private

    def fresh_prompt_mode(fresh, active)
      return nil unless fresh.participant?

      id = Steer.participant_id(fresh.author)
      active.any? { |entry| entry.id == id } && fresh.pair? ? :pair : nil
    end

    def source_id(session)
      return nil unless session

      session.respond_to?(:participants_source_id) ? session.participants_source_id : session.id
    end

    def read
      return [] if @session_id.to_s.empty?

      dir = Session.session_dir(@session_id, state_dir: @state_dir.call)
      return [] unless File.exist?(File.join(dir, "participants.json"))

      Participants.read(@session_id, state_dir: @state_dir.call)
    rescue StandardError
      []
    end
  end
end
