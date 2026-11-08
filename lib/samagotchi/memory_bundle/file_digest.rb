# frozen_string_literal: true

require "digest"

module Samagotchi
  module MemoryBundle
    # The one digest of a file on disk, so the sha256 written by a record and
    # the one read back at load time come from the same code.
    #
    # Only files are digested here. Bytes already in memory (a merged file's
    # text, a memory's content that is also its base) keep their own
    # Digest::SHA256.hexdigest call at the place that has them.
    module FileDigest
      # The file's SHA256 hex, read as bytes and streamed. nil when +path+
      # isn't a file (missing, or a directory); an unreadable file raises
      # SystemCallError, which callers that must keep going rescue.
      def self.hex(path)
        return nil unless File.file?(path)

        Digest::SHA256.file(path).hexdigest
      end

      # The form a manifest or a record writes for a hook, rule, plugin or
      # script: "sha256:<hex>", nil for a file that isn't there.
      def self.sha256(path)
        hex = hex(path)
        hex && "sha256:#{hex}"
      end

      # The integrity check's one warning: +path+'s bytes against the sha
      # hex a manifest declares for it. nil when they match, or when there is
      # nothing to check (no sha declared, no file).
      # @param label [String] what the file is ("a.md", "hook guard.rb")
      def self.mismatch(label, path, expected)
        return nil if expected.nil? || expected.empty?

        actual = hex(path)
        return nil if actual.nil? || actual == expected

        "Checksum mismatch for #{label}: expected #{expected[0..7]}..., got #{actual[0..7]}..."
      end
    end
  end
end
