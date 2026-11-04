# frozen_string_literal: true

require "digest"

module Samagotchi
  module MemoryBundle
    # 3-way merge helper for bundle upgrades.
    #
    # Compare base (provenance snapshot), current (on-disk), incoming (new bundle)
    # and classify per file. Used by Installer#run when provenance exists.
    module Merger
      # What an upgrade does to one file. status names the case; base is where
      # the file's next base comes from:
      #   :on_disk   the file as the install leaves it: it took the bundle's
      #              bytes, or already had them.
      #   :recorded  the base it has (none stays none): the file stays as the
      #              user has it, and the next upgrade must still see the edit.
      # Installer#next_base reads it. A new outcome and its base go here; it
      # also needs a branch in Installer#merge_memory (which raises without
      # one), #next_base if its base is a new kind, and its status word in
      # Installer#preview_memory, #verify_memory_checksums' list and #summary.
      Outcome = Data.define(:status, :base) do
        def conflict? = status == :conflict
      end

      INSTALL = Outcome.new(status: :install, base: :on_disk)
      FAST_FORWARD = Outcome.new(status: :fast_forward, base: :on_disk)
      NOOP = Outcome.new(status: :noop, base: :on_disk)
      KEEP = Outcome.new(status: :keep, base: :recorded)
      CONFLICT = Outcome.new(status: :conflict, base: :recorded)
      # Nothing to take: the bundle has no such file, so whatever is on disk
      # (the user's text, perhaps) must not become the base. A noop to callers.
      NO_INCOMING = Outcome.new(status: :noop, base: :recorded)

      # Classify a single file for upgrade.
      # @return [Outcome]
      def self.classify(base_path:, current_path:, incoming_path:)
        base_exists = base_path && File.exist?(base_path)
        current_exists = File.exist?(current_path)
        incoming_exists = File.exist?(incoming_path)

        return NO_INCOMING unless incoming_exists

        unless current_exists
          return INSTALL
        end

        # No base (legacy bundle without provenance or first file) -> treat as modified
        unless base_exists
          incoming_digest = Digest::SHA256.hexdigest(File.read(incoming_path))
          current_digest = Digest::SHA256.hexdigest(File.read(current_path))
          return current_digest == incoming_digest ? NOOP : CONFLICT
        end

        base_digest = Digest::SHA256.hexdigest(File.read(base_path))
        current_digest = Digest::SHA256.hexdigest(File.read(current_path))
        incoming_digest = Digest::SHA256.hexdigest(File.read(incoming_path))

        if current_digest == incoming_digest
          NOOP
        elsif current_digest == base_digest
          FAST_FORWARD
        elsif incoming_digest == base_digest
          KEEP
        else
          CONFLICT
        end
      end

      # A line a merge tool leaves around a conflict. "=======" isn't one: it
      # is also a Markdown heading's underline.
      CONFLICT_MARKER = /^(?:<{7}|>{7})(?: |$)/

      # Whether the file holds a merge's conflict markers.
      def self.markers?(path)
        File.exist?(path) && File.binread(path).match?(CONFLICT_MARKER)
      end

      # The file's digest, nil when there is none.
      def self.digest(path)
        File.exist?(path) ? Digest::SHA256.hexdigest(File.binread(path)) : nil
      end

      def self.current_modified?(base_path, current_path)
        return true unless base_path && File.exist?(base_path) && File.exist?(current_path)

        Digest::SHA256.hexdigest(File.read(base_path)) != Digest::SHA256.hexdigest(File.read(current_path))
      end
    end
  end
end
