# frozen_string_literal: true

require "json"
require "fileutils"

require_relative "session"

module Samagotchi
  # The idle recap saved with its session, in <session dir>/recap.json:
  #   {text, covered, covered_digest, model, created_at}
  # A separate file, so it never races the session-file save at the end of a
  # turn. Follows the Engine's current session (the REPL can switch).
  class RecapStore
    FILE = "recap.json"
    # A session card's or the picker's recap line.
    PREVIEW_CHARS = 140
    # "The user was testing…" / "The user and the assistant were exploring…":
    # the recap prompt opens with the user's task this way, which spent ~30
    # of a card's visible characters on the same words every time. Only a
    # subject plus an -ing verb; anything else is left as it is.
    SUBJECT_RE = /\AThe user(?: and (?:the )?assistant)? (?:was|were|is|are) (?=[a-z]+ing\b)/

    # @param session_id_lookup [#call] the current session's id, or nil
    # @param state_dir_lookup [#call] the state dir holding the sessions
    def initialize(session_id_lookup:, state_dir_lookup:)
      @session_id_lookup = session_id_lookup
      @state_dir_lookup = state_dir_lookup
    end

    # @return [String, nil] the session the store reads and writes now
    def key
      @session_id_lookup.call
    end

    # @return [Hash, nil] the saved recap (symbol keys), nil when none
    def load
      id = key
      id && self.class.read(Session.session_dir(id, state_dir: @state_dir_lookup.call))
    end

    # Write +state+ atomically. Skipped when the session file is gone (deleted,
    # or discarded as empty), so this never recreates a removed session's dir.
    def save(state)
      id = key
      return unless id

      state_dir = @state_dir_lookup.call
      return unless File.exist?(File.join(state_dir, "#{id}.json"))

      dir = Session.session_dir(id, state_dir: state_dir)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, FILE)
      File.write("#{path}.tmp", JSON.generate(state))
      File.rename("#{path}.tmp", path)
    end

    # @return [Hash, nil] the recap saved in +session_dir+, nil when there is
    #   none or it can't be read
    def self.read(session_dir)
      data = JSON.parse(File.read(File.join(session_dir, FILE)), symbolize_names: true)
      return nil unless data.is_a?(Hash) && !data[:text].to_s.strip.empty?

      data
    rescue StandardError
      nil
    end

    # @return [String, nil] the first sentence of the recap saved in
    #   +session_dir+, on one line, without the subject phrase (SUBJECT_RE)
    #   and cut to PREVIEW_CHARS. The full recap keeps its sentence.
    def self.preview(session_dir)
      text = read(session_dir)&.dig(:text).to_s.gsub(/\s+/, " ").strip
      return nil if text.empty?

      first = text[/\A.*?[.!?](?=\s|\z)/] || text
      first = first.sub(SUBJECT_RE, "").sub(/\A[a-z]/, &:upcase)
      first.length > PREVIEW_CHARS ? "#{first[0, PREVIEW_CHARS - 1]}…" : first
    end
  end
end
