# frozen_string_literal: true

require_relative "file_digest"

module Samagotchi
  module InstalledBundles
    # The sha256 a record keeps for an installed file, and whether the file
    # on disk is still it.
    module Sha
      # What a dev install (`chi bundle install --dev`) records instead of
      # a sha256: its files are links to the source, which change under it.
      # Not a hex digest, so no file can be mistaken for it.
      DEV = "sha256:dev"

      # The hex digest a manifest records, in either of its formats:
      # "sha256:<hex>" (hooks, rules, the plugin) or bare <hex> (a memory
      # file's checksum:). "" when none is recorded.
      def self.recorded(value)
        value.to_s.delete_prefix("sha256:")
      end

      # The digest of a file, nil when it isn't there (FileDigest). Every
      # caller checks existence first; .matches? reads a missing file as
      # not the recorded one.
      def self.of_file(path)
        FileDigest.hex(path)
      end

      # Whether +value+ is DEV: the file isn't checked.
      def self.unchecked?(value)
        recorded(value) == recorded(DEV)
      end

      # Whether the file's content is the one recorded (either format); a
      # dev install's (DEV) always is.
      def self.matches?(path, value)
        unchecked?(value) || of_file(path) == recorded(value)
      end
    end
  end
end
