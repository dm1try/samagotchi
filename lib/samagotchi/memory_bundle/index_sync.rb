# frozen_string_literal: true

require_relative "index_updater"
require_relative "../tools/memory"
require_relative "../model_overlay"
require_relative "../log"

module Samagotchi
  module MemoryBundle
    # Keeps a memory's managed index.md line current when the file tools
    # (write, edit) change it, as memory_write does: the ToolRunner calls
    # .refresh after a write/edit that changed its file (one it could diff:
    # a memory over 1 MB isn't refreshed). The line's description is kept.
    #
    # Only a *.md right in the project or system memories dir (the dirs
    # memory_write writes to) counts: not index.md, not a hidden file, not a
    # model overlay (<name>.<key>.md next to its <name>.md; a memory whose
    # name has a dot and a sibling of the same stem reads as an overlay too,
    # a leftover ambiguity). Writes into another project's folder and
    # execute's writes aren't seen.
    module IndexSync
      SCOPES = %w[project system].freeze

      # @param path [String] the file write/edit changed
      # @return [Boolean] whether an index line was written
      def self.refresh(path)
        path = File.expand_path(path.to_s)
        scope = memory_scope(path)
        return false unless scope && File.file?(path)

        name = File.basename(path, ".md")
        return false if ModelOverlay.overlay_file?(path)

        IndexUpdater.update_index(scope, name, File.size(path), nil)
      rescue StandardError => e
        Log.warn(:memory, "index_sync_failed", path: path, error: "#{e.class}: #{e.message}")
        false
      end

      # "project" or "system" when +path+ is a memory's file (or an
      # overlay's): a *.md right in that scope's memories dir, not index.md (in any case),
      # not hidden, not a symlink. nil otherwise. The guardrails' outside_repo
      # uses it too: write/edit there is what memory_write does. A symlink
      # isn't: write/edit follow it to wherever it points, memory_write
      # replaces the link.
      def self.memory_scope(path)
        path = File.expand_path(path.to_s)
        name = File.basename(path, ".md")
        return nil unless File.extname(path) == ".md"
        # Any case: on a case-insensitive disk INDEX.md is the index itself.
        return nil if name.casecmp?(IndexUpdater::MEMORY_INDEX) || name.start_with?(".") || File.symlink?(path)

        dir = real(File.dirname(path))
        SCOPES.find { |s| real(Tools::MemoryRead.memories_dir(s)) == dir }
      rescue StandardError
        nil
      end

      def self.real(dir)
        File.realpath(dir)
      rescue SystemCallError
        File.expand_path(dir)
      end
    end
  end
end
