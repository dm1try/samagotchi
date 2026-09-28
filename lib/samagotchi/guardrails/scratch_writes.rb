# frozen_string_literal: true

require_relative "protected_paths"
require_relative "../memory_paths"

module Samagotchi
  module Guardrails
    # A `chi scratch` session saves nothing: write and edit on a file under
    # the memories folder (system and project memories, overlays, index.md)
    # are denied. (memory_write itself refuses in a scratch session, with a
    # shorter answer: Engine.) Reading them is fine. execute can still
    # write there (as with ProtectedPaths).
    class ScratchWrites
      REASON = "scratch session: nothing is saved"
      RULE = "scratch-session"

      # @param memories_dir [#call] the memories folder (MemoryPaths.system_dir),
      #   read per call like the memory tools do
      def initialize(memories_dir: -> { MemoryPaths.system_dir })
        @memories_dir = memories_dir
      end

      # Vote on +verdict+.
      def check(verdict)
        return verdict unless writes_memory?(verdict)

        verdict.deny!(REASON, rule: RULE, source: ProtectedPaths::SOURCE, decided_by: "core")
      end

      private

      def writes_memory?(verdict)
        targets = verdict.targets
        return false unless targets && %w[write edit].include?(targets.tool)

        targets.paths.any? { |path| ProtectedPaths.within?(ProtectedPaths.real(path), @memories_dir.call) }
      end
    end
  end
end
