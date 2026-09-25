# frozen_string_literal: true

require_relative "tools/memory"

module Samagotchi
  # Memories hidden from one session (`--mute NAME`): name normalization and
  # the index-text filter, shared by the Engine (the prompt's index, the
  # identity auto-load, the preload list) and the KernelLoop (a memory_read
  # guard). Nothing on disk changes: a muted memory keeps its file and its
  # index line.
  module MutedMemories
    # A managed index line (IndexUpdater.managed_line), plus the legacy
    # `- **name**: desc` and `- **name.md** ·` shapes still found in indexes.
    INDEX_LINE = /\A- \*\*(.+?)\*\*[ \t]*(?:[·•].*|:.*)?\z/

    # `project/gh-helper`, `gh-helper.md`, ` gh-helper ` → `gh-helper`.
    # nil for a blank name.
    def self.normalize(raw)
      value = raw.to_s.strip
      return nil if value.empty?

      if value.include?("/")
        scope, rest = value.split("/", 2)
        value = rest if Tools::VALID_SCOPES.include?(scope)
      end
      base = File.basename(value, ".md").strip
      base.empty? ? nil : base
    end

    # Names as given (comma lists allowed) → normalized, deduped.
    def self.normalize_list(names)
      Array(names).flat_map { |raw| raw.to_s.split(",") }.map { |n| normalize(n) }.compact.uniq
    end

    def self.muted?(name, muted)
      return false if muted.nil? || muted.empty?

      key = normalize(name)
      !key.nil? && muted.include?(key)
    end

    # The index text without the lines that name a muted memory: a managed
    # line (`- **name** · …`) or a bare name (the "no index yet" fallback).
    # Every other byte stays.
    def self.filter_index(text, muted)
      return text if muted.nil? || muted.empty? || text.nil?

      text.each_line.reject { |line| muted_index_line?(line, muted) }.join
    end

    def self.muted_index_line?(line, muted)
      stripped = line.chomp
      name = stripped.match(INDEX_LINE)&.[](1) || stripped
      return false if name.include?(" ")

      muted?(name, muted)
    end
  end
end
