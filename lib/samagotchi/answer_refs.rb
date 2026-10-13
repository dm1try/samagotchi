# frozen_string_literal: true

require "json"
require_relative "log"
require_relative "ref"
require_relative "row_refs"

module Samagotchi
  # One ref on the answer: the text it stands for (+match+, what the page
  # pairs it with) and the Ref itself. +to_h+ is the stored and sent shape,
  # {match:, kind:, target:, label:, actions:}.
  AnswerRef = Data.define(:match, :ref) do
    # @raise [ArgumentError] an empty match, one over MAX_MATCH, or a ref
    #   that isn't a Ref
    def initialize(match:, ref:)
      match = match.to_s.strip
      raise ArgumentError, "a ref needs a match (the text it stands for)" if match.empty?
      raise ArgumentError, "a ref's match is at most #{AnswerRef::MAX_MATCH} characters" if match.length > AnswerRef::MAX_MATCH
      raise ArgumentError, "not a Ref" unless ref.is_a?(Ref)

      super
    end

    def to_h = { match: match, **ref.to_h }
  end

  class AnswerRef
    MAX_MATCH = 500

    # A hook's {match:, kind:, target:, label:, actions:}, or a stored
    # entry (String or Symbol keys, nested ones too). A file ref is held to
    # the session's folder as a plugin row's is (RowRefs.inside, plan D7):
    # +roots+ is RowRefs.roots of it; a relative path is resolved against
    # it (+relative+; a stored one was stored absolute, so it is dropped),
    # a path outside it refused, and the path kept under its real
    # spelling. With no folder (no +roots+), an absolute path stays.
    # @raise [ArgumentError] anything invalid
    def self.from(value, roots: [], relative: true)
      raise ArgumentError, "a ref is a Hash {match:, kind:, target:, label:, actions:}" unless value.is_a?(Hash)

      value = value.transform_keys(&:to_sym)
      ref = Ref.new(kind: value[:kind], target: value[:target], label: value[:label], actions: value[:actions] || [])
      new(match: value[:match], ref: RowRefs.inside(ref, roots, relative))
    end
  end

  # The refs after_turn hooks attach to a turn's answer (event[:refs]),
  # kept as `display_refs` on the answer's model message next to its
  # `display` (AnswerDisplay). Display only, like `display`: the model
  # never sees them (AnswerDisplay::DISPLAY_ONLY), and a UI pairs each with
  # its +match+ in the shown answer (or drops it).
  #
  # The target is AnswerDisplay's: the stored conversation's last message
  # when it is the model's. The list starts from the refs it already has
  # (re-validated), so a later hook run never loses them.
  class AnswerRefs
    KEY = :display_refs
    MAX_REFS = 200
    # The list's JSON; a ref that would cross it is refused.
    MAX_BYTES = 256 * 1024

    # Stored refs (+raw+, as read from session.json or a snapshot), each
    # rebuilt and checked again, the caps applied; what isn't valid any
    # more is dropped. Never raises: a reload must show the conversation.
    # A relative file path is dropped (it was stored absolute), and with
    # +cwd+ (the session's folder) a file outside it.
    # @return [Array<Hash>] the refs to send ({match:, kind:, target:, …})
    def self.for_display(raw, cwd: nil)
      return [] if raw.nil?

      kept = new([{ role: "model", KEY => raw }], cwd: cwd).to_a
      dropped = raw.is_a?(Array) ? raw.length - kept.length : 1
      Log.debug(:web, "display_refs_dropped", count: dropped) if dropped.positive?
      kept
    rescue StandardError
      []
    end

    # @return [Hash, nil] the message event[:refs] adds to
    attr_reader :target

    # @param messages [Array<Hash>] the conversation the turn stored
    # @param cwd [String, nil] the session's folder, for relative file paths
    def initialize(messages, cwd:)
      last = Array(messages).last
      @target = last if last.is_a?(Hash) && (last[:role] || last["role"]).to_s == "model"
      @roots = RowRefs.roots(cwd)
      @refs = []
      @seen = {}
      @bytes = 2 # the list's []
      @added = false
      @closed = false
      @rejections = Hash.new(0)
      seed(@target) if @target
    end

    # True when a hook added a ref the answer didn't have.
    def added? = @added

    def count = @refs.length

    # @return [Array<Hash>] the refs as stored ({match:, kind:, target:, …})
    def to_a = @refs.dup

    # The list is stored (Engine#store_answer_display): a later call (a
    # plugin that kept event[:refs]) would be lost, so it returns nil.
    def close! = @closed = true

    def closed? = @closed

    # event[:refs]: call it with the ref's keywords,
    # +call(match:, kind:, target:, label: nil, actions: [])+.
    # @param event [Hash] the after_turn event (for its :hook label)
    # The hook's label is read at call time: one adder serves every hook of
    # the fire, and the registry sets event[:hook] before each.
    # @return [Proc] true when the ref is kept (or was already there), false
    #   when it is refused (logged, named by event[:hook]), nil when the
    #   turn has no answer or the list was already stored (#close!)
    def adder(event)
      lambda do |*args, **ref|
        next nil unless @target
        next late(event[:hook]) if @closed
        next reject(event[:hook], "takes keywords (match:, kind:, target:, label:, actions:)") unless args.empty?

        add(ref, event[:hook])
      end
    end

    private

    KEYS = %i[match kind target label actions].freeze
    REASON_VALUES = /\(.*?\)|\[.*?\]|".*?"|\d+/
    private_constant :KEYS, :REASON_VALUES

    def seed(target)
      raw = target[KEY] || target[KEY.to_s]
      raw.each { |entry| keep(entry) } if raw.is_a?(Array)
    end

    def add(value, hook)
      unknown = value.keys - KEYS
      return reject(hook, "has unknown keys #{unknown.map(&:to_s).inspect}") unless unknown.empty?

      entry = AnswerRef.from(value, roots: @roots).to_h
      return true if @seen.key?(entry)
      return over_cap(hook, "#{MAX_REFS} refs") if @refs.length >= MAX_REFS

      size = JSON.generate(entry).bytesize + (@refs.empty? ? 0 : 1)
      return over_cap(hook, "#{MAX_BYTES / 1024} KiB") if @bytes + size > MAX_BYTES

      push(entry, size)
      @added = true
    rescue StandardError => e
      reject(hook, e.message)
    end

    # A stored entry back in the list, checked again (a relative path is
    # dropped: it was stored absolute; so is a file outside the folder).
    # Duplicates and what is over the caps go quietly.
    # @return [Boolean] kept
    def keep(raw)
      entry = AnswerRef.from(raw, roots: @roots, relative: false).to_h
      return false if @seen.key?(entry) || @refs.length >= MAX_REFS

      size = JSON.generate(entry).bytesize + (@refs.empty? ? 0 : 1)
      return false if @bytes + size > MAX_BYTES

      push(entry, size)
      true
    rescue StandardError
      false
    end

    def push(entry, size)
      @refs << entry
      @seen[entry] = true
      @bytes += size
    end

    def over_cap(hook, cap) = reject(hook, "over the cap (#{cap})")

    def late(hook)
      Log.debug(:hooks, "refs_late", hook: hook.to_s)
      nil
    end

    # Each reason is said once per hook per answer (a warn and its echo);
    # the same again goes to debug with its count, so a hook looping over
    # bad refs can't flood the terminal. The reason's values (a kind, a
    # key list, a cap) don't make it a new one.
    def reject(hook, why)
      count = @rejections[[hook.to_s, why.gsub(REASON_VALUES, "")]] += 1
      if count == 1
        Log.warn(:hooks, "refs_rejected", echo: "[samagotchi:hooks] #{hook}: ref #{why}; dropped",
                                          hook: hook.to_s, reason: why)
      else
        Log.debug(:hooks, "refs_rejected", hook: hook.to_s, reason: why, count: count)
      end
      false
    end
  end
end
