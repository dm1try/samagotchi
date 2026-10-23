# frozen_string_literal: true

module Samagotchi
  # One item of the working set the user pinned (/working-set pin): its
  # identity as WorkingSet names an item, +kind+ file|memory|url and +key+
  # (a file's absolute path, a memory's name, a URL). The model's
  # forget_outputs refuses its outputs, the ones it has and the ones it
  # reads later (WorkingSetSteer). Saved as the session's
  # working_set_pins ([{"kind", "key"}]); a respawn, a continue and a fork
  # keep them (SessionSetup).
  WorkingSetPin = Data.define(:kind, :key) do
    def initialize(kind:, key:)
      super(kind: kind.to_s, key: key.to_s)
    end

    # The session file's form.
    def to_file = { "kind" => kind, "key" => key }

    # +value+'s pins, in order, no repeats: pins, or a file's Hashes
    # (string or symbol keys); anything else (a hand-edited entry without
    # a kind or key) is left out.
    # @return [Array<WorkingSetPin>] frozen
    def self.list(value)
      Array(value).filter_map do |entry|
        next entry if entry.is_a?(WorkingSetPin)
        next unless entry.is_a?(Hash)

        kind = entry["kind"] || entry[:kind]
        key = entry["key"] || entry[:key]
        new(kind: kind, key: key) unless kind.to_s.empty? || key.to_s.empty?
      end.uniq.freeze
    end
  end
end
