# frozen_string_literal: true

module Samagotchi
  # Which models a `models:` list is for, in one grammar shared by the
  # guardrails rules' `models:`, `guardrails.small_models` and the model
  # notes' first line: entries `|`-separated (or a list), each `small` (the
  # caller says whether the model is a small one) or an fnmatch glob
  # (case-insensitive, extglob) on the bare model name or the model key
  # (ModelOverlay.key_for). Any entry matching wins; no model matches
  # nothing.
  module ModelMatch
    GLOB_FLAGS = File::FNM_CASEFOLD | File::FNM_EXTGLOB
    SMALL = "small"

    module_function

    # The entries of a `models:` value: a string, or a list of them, each
    # split on `|`, stripped, blanks dropped.
    # @param value [String, Array<String>, nil]
    # @return [Array<String>]
    def parse(value)
      Array(value).flat_map { |entry| entry.to_s.split("|") }.map(&:strip).reject(&:empty?)
    end

    # @param entries [Array<String>] parsed entries (#parse)
    # @param name [String, nil] the bare model name
    # @param key [String, nil] its model key
    # @param small [#call] → whether the model is a small one; called only
    #   for a `small` entry
    def match?(entries, name:, key:, small:)
      return false if name.nil? || name.to_s.empty?

      entries.any? { |entry| entry == SMALL ? small.call : glob?(entry, name: name, key: key) }
    end

    # Whether the glob +entry+ matches the name or the key.
    def glob?(entry, name:, key:)
      [name, key].compact.any? { |candidate| File.fnmatch(entry, candidate.to_s, GLOB_FLAGS) }
    end
  end
end
