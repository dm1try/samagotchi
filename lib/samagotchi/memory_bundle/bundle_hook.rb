# frozen_string_literal: true

module Samagotchi
  module MemoryBundle
    # One class-file hook's sha256 in an older chi's installed record; its
    # other fields are ignored now that class-file hooks are retired.
    BundleHook = Data.define(:sha256) do
      def initialize(sha256: "") = super

      # @param raw [Hash, BundleHook, nil] string or symbol keys; legacy
      #   metadata beyond sha256 is ignored
      def self.parse(raw)
        return raw if raw.is_a?(BundleHook)

        h = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
        new(sha256: prefixed(h["sha256"]))
      end

      # "sha256:<hex>" from either form, "" for none.
      def self.prefixed(sha)
        sha = sha.to_s.strip
        sha.empty? || sha.start_with?("sha256:") ? sha : "sha256:#{sha}"
      end
    end
  end
end
