# frozen_string_literal: true

require "json"
require_relative "atomic_file"
require_relative "grants"
require_relative "log"
require_relative "prompt_history"

module Samagotchi
  # Each participant's own prompts in one session, the list their
  # composer's ↑/↓ walks (chi web's ParticipantHistory serves it, redacted,
  # to that grant only). Written by chi web when it accepts a participant's
  # turn, never derived from a message, a body field or an author the page
  # sends; the owner's PromptHistory (the machine-wide file) is never
  # written or read for a participant.
  #
  # participant_prompts.json in the session folder (beside
  # participants.json, not in images/), 0600, written whole (AtomicFile):
  # {prompts: {<grant id>: [text, …]}}, oldest first. At most LIMIT per
  # grant; a text over MAX_ENTRY_BYTES isn't recorded (a cut prompt
  # recalled and re-sent would be another message). Keys are grant ids
  # (Grants::ID_RE) still known to the grants store: an append drops the
  # others. A file that doesn't read is never written over (Log.warn) and
  # reads as no entries; the owner can delete it. Callers serialize
  # read-then-write themselves (chi web's @participant_prompts_mutex).
  # See docs/internals/participants.md.
  module ParticipantPrompts
    FILE = "participant_prompts.json"
    LIMIT = PromptHistory::LIMIT
    MAX_ENTRY_BYTES = 16 * 1024

    # What the file holds: +prompts+ grant id => [String] (only ID_RE keys,
    # only String entries); +broken+ when it doesn't read.
    State = Data.define(:prompts, :broken)
    BROKEN = State.new(prompts: {}.freeze, broken: true)

    module_function

    # @return [State]
    def read(dir)
      path = File.join(dir, FILE)
      return State.new(prompts: {}, broken: false) unless File.exist?(path)

      data = JSON.parse(File.read(path))
      raise TypeError, "not an object" unless data.is_a?(Hash)

      prompts = data.fetch("prompts", {})
      raise TypeError, "prompts not an object" unless prompts.is_a?(Hash)

      kept = prompts.each_with_object({}) do |(grant_id, list), out|
        next unless grant_id?(grant_id)

        out[grant_id] = list.is_a?(Array) ? list.grep(String) : []
      end
      State.new(prompts: kept, broken: false)
    rescue JSON::ParserError, SystemCallError, TypeError => e
      Log.warn(:web, "participant_prompts_unreadable", file: path, msg: e.message)
      BROKEN
    end

    # +grant_id+'s prompts, oldest first: a new array of theirs only; []
    # for an unknown grant, a bad id or a broken file.
    # @return [Array<String>]
    def entries(dir, grant_id)
      return [] unless grant_id?(grant_id)

      read(dir).prompts.fetch(grant_id, []).dup
    end

    # The text as it would be kept (PromptHistory.normalize's), nil when it
    # isn't kept: empty, or over MAX_ENTRY_BYTES.
    # @return [String, nil]
    def recordable(text)
      line = PromptHistory.normalize([text]).first
      line if line && line.bytesize <= MAX_ENTRY_BYTES
    end

    # Records +text+ as +grant_id+'s newest prompt, keeping its last LIMIT;
    # the lists of grants not in +live_grant_ids+ are dropped. A broken
    # file, a bad grant id or a text #recordable refuses writes nothing.
    # @param live_grant_ids [Array<String>] the session's grants the grants
    #   store still knows (active or not yet swept)
    # @return [Boolean] whether it was recorded
    def append(dir, grant_id:, text:, live_grant_ids:)
      return false unless grant_id?(grant_id)

      line = recordable(text) or return false
      state = read(dir)
      return false if state.broken

      live = Array(live_grant_ids) | [grant_id]
      prompts = state.prompts.slice(*live)
      prompts[grant_id] = (prompts.fetch(grant_id, []) + [line]).last(LIMIT)
      body = { "prompts" => prompts }
      AtomicFile.write(File.join(dir, FILE), "#{JSON.pretty_generate(body)}\n", perm: 0o600)
      true
    end

    def grant_id?(grant_id) = grant_id.is_a?(String) && Grants::ID_RE.match?(grant_id)
  end
end
