# frozen_string_literal: true

module Samagotchi
  # Loaded only when a sidecar is read: it brings Web::Grants (and Rack).
  autoload :Participants, File.expand_path("participants", __dir__)

  # Who is in a session's review now, and who came or went since the last
  # look: participants.json (Participants.read) read again when its mtime
  # moves, each entry's expiry measured at every look. The worker asks
  # #changes on its idle tick and announces :participants_changed; the
  # Bridge's join snapshot asks #active (any thread). A session nobody was
  # invited to has no sidecar: one stat per look. Joined means invited (an
  # active grant the last look didn't have), left means revoked or expired:
  # participants have no presence of their own yet. See
  # docs/internals/participants.md (The owner's terminal).
  class ParticipantsWatch
    # Participants::FILE, without loading Participants for a stat.
    FILE = "participants.json"

    # What changed: the active participants now, the ones that joined, and
    # the ones that left (each with +reason+ "revoked" or "expired").
    Change = Data.define(:participants, :joined, :left) do
      def to_event = { type: :participants_changed, participants: participants, joined: joined, left: left }
    end

    # @param session_id [#call] → the session's id (nil before it has one)
    # @param state_dir [#call] → the sessions' state dir
    # @param clock [#call] → Time
    def initialize(session_id:, state_dir:, clock: -> { Time.now })
      @session_id = session_id
      @state_dir = state_dir
      @clock = clock
      @mutex = Mutex.new
      @stamp = nil
      @entries = []
      @known = nil
    end

    # The participants in the review now: [{id:, name:, kind:}], [] for none.
    # @return [Array<Hash>]
    def active
      @mutex.synchronize { active_rows(read_entries) }
    end

    # The change since the last call, nil when none. The first call only
    # takes the state as it is (a worker's start announces nobody).
    # @return [Change, nil]
    def changes
      @mutex.synchronize do
        entries = read_entries
        rows = active_rows(entries)
        known = @known
        @known = rows.to_h { |row| [row[:id], row] }
        next nil if known.nil?

        joined = rows.reject { |row| known.key?(row[:id]) }
        left = known.values.reject { |row| @known.key?(row[:id]) }.map do |row|
          entry = entries.find { |e| e.id == row[:id] }
          row.merge(reason: entry&.removed_at ? "revoked" : "expired")
        end
        next nil if joined.empty? && left.empty?

        Change.new(participants: rows, joined: joined, left: left)
      end
    end

    private

    def active_rows(entries)
      now = @clock.call
      entries.select { |entry| entry.active?(now) }.map { |entry| { id: entry.id, name: entry.name, kind: entry.kind } }
    end

    # The sidecar's entries, read again only when its mtime moved.
    def read_entries
      id = @session_id.call
      return @entries = [] if id.to_s.empty?

      file = File.join(Session.session_dir(id, state_dir: @state_dir.call), FILE)
      stamp = [id, File.mtime(file)]
      return @entries if stamp == @stamp

      @stamp = stamp
      @entries = Participants.read(id, state_dir: @state_dir.call)
    rescue SystemCallError
      @stamp = nil
      @entries = []
    end
  end
end
