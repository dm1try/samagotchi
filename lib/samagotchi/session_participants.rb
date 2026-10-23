# frozen_string_literal: true

module Samagotchi
  # Loaded only when a session is read: it brings Web::Grants (and Rack).
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
    def refresh!(session)
      @session_id = session&.id
      @entries = read
      self
    end

    # The name +author+ ("p:<id>") had when it was invited, nil for none
    # (the owner, or a participant the sidecar doesn't name). A miss reads
    # the sidecar again: someone invited after the turn began.
    def name_for(author)
      return nil unless Steer.participant_author?(author)

      id = author.to_s.delete_prefix("p:")
      entry = @entries.find { |e| e.id == id } || (@entries = read).find { |e| e.id == id }
      entry&.name
    end

    private

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
