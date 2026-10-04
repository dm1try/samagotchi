# frozen_string_literal: true

require "digest"

module Samagotchi
  module MemoryBundle
    # 3-way merge helper for bundle upgrades.
    #
    # Compare base (provenance snapshot), current (on-disk), incoming (new bundle)
    # and classify per file. Used by Installer#run when provenance exists.
    module Merger
      # Classify a single file for upgrade.
      # Returns :install, :keep, :fast_forward, :conflict, :noop
      def self.classify(base_path:, current_path:, incoming_path:)
        base_exists = base_path && File.exist?(base_path)
        current_exists = File.exist?(current_path)
        incoming_exists = File.exist?(incoming_path)

        return :noop unless incoming_exists

        unless current_exists
          return :install
        end

        # No base (legacy bundle without provenance or first file) -> treat as modified
        unless base_exists
          incoming_digest = Digest::SHA256.hexdigest(File.read(incoming_path))
          current_digest = Digest::SHA256.hexdigest(File.read(current_path))
          return current_digest == incoming_digest ? :noop : :conflict
        end

        base_digest = Digest::SHA256.hexdigest(File.read(base_path))
        current_digest = Digest::SHA256.hexdigest(File.read(current_path))
        incoming_digest = Digest::SHA256.hexdigest(File.read(incoming_path))

        if current_digest == incoming_digest
          :noop
        elsif current_digest == base_digest
          :fast_forward
        elsif incoming_digest == base_digest
          :keep
        else
          :conflict
        end
      end

      def self.current_modified?(base_path, current_path)
        return true unless base_path && File.exist?(base_path) && File.exist?(current_path)

        Digest::SHA256.hexdigest(File.read(base_path)) != Digest::SHA256.hexdigest(File.read(current_path))
      end
    end
  end
end
