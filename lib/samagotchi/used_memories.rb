# frozen_string_literal: true

require "monitor"

require_relative "muted_memories"
require_relative "tools/memory"
require_relative "tools/read"

module Samagotchi
  # The memories a session used: the ones its turns read (memory_read, or a
  # read of a memories/*.md file) or preloaded. Deduped, in first-use
  # order. Written by the turn thread (and the main thread setting the
  # session), read by any (the bridge's snapshot, the UIs).
  class UsedMemories
    # The memory names a tool call reads, or nil when it reads none.
    # @param call [Hash] {name:, content:}
    # @return [Array<String>, String, nil]
    def self.names_from_call(call)
      return nil unless call.is_a?(Hash)

      content = call[:content].to_s.strip
      return nil if content.empty?

      case call[:name].to_s
      when Tools::MemoryRead::NAME
        Tools::MemoryRead.parse_names(content).filter_map { |name| normalize(name) }
      when Tools::Read::NAME
        path = content.tr("\\", "/")
        path.match?(%r{memories/.+\.md\z}) ? normalize(path) : nil
      end
    end

    # A memory's name as the list keeps it: the basename without .md.
    def self.normalize(raw)
      value = raw.to_s.strip
      return nil if value.empty?

      base = File.basename(value, ".md").strip
      base.empty? ? nil : base
    end
    private_class_method :normalize

    # @param names [Array<String>] the names already used (a resumed session's)
    def initialize(names = [])
      @lock = Monitor.new
      @names = []
      add(names)
    end

    # @return [Array<String>] a copy of the list
    def names
      @lock.synchronize { @names.dup }
    end

    # Add names, skipping blanks and ones already there.
    def add(names)
      @lock.synchronize do
        Array(names).each do |name|
          value = name.to_s.strip
          @names << value unless value.empty? || @names.include?(value)
        end
      end
      self
    end

    # Add the names a session already used.
    def absorb(session)
      return self unless session

      add(Array(session.used_memory_names))
    end

    # A memory read as it starts (:tool_call_started): its names join the
    # list. A refused read of a muted memory is not a use of it.
    # @param muted [Array<String>] the session's muted names (normalized)
    # @return [Array<String>, nil] the names this call read, nil for any other event
    def capture(event, muted:)
      return nil unless event.is_a?(Hash) && event[:type] == :tool_call_started

      call = event[:call].is_a?(Hash) ? event[:call] : {}
      names = Array(self.class.names_from_call(call)).reject { |name| MutedMemories.muted?(name, muted) }
      return nil if names.empty?

      add(names)
      names
    end
  end
end
