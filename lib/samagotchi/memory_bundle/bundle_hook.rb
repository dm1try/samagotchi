# frozen_string_literal: true

require "digest"

module Samagotchi
  module MemoryBundle
    # One hook's metadata, as a bundle's manifest.yml declares it and its
    # installed record (manifest.json) keeps it: the file's sha256
    # ("sha256:<hex>", "" when none is recorded), the event it registers
    # for ("" when none: it isn't loaded), on_error (skip, log or
    # fail_closed) and priority. The one place the defaults live.
    class BundleHook < Data.define(:sha256, :event, :on_error, :priority)
      DEFAULT_ON_ERROR = "skip"
      DEFAULT_PRIORITY = 100

      def initialize(sha256: "", event: "", on_error: DEFAULT_ON_ERROR, priority: DEFAULT_PRIORITY)
        super
      end

      # @param raw [Hash, BundleHook, nil] string keys (manifest.yml) or
      #   symbol keys (a read record); missing or blank values get the
      #   defaults
      def self.parse(raw)
        return raw if raw.is_a?(BundleHook)

        h = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
        on_error = h["on_error"].to_s.strip
        new(sha256: prefixed(h["sha256"]), event: h["event"].to_s.strip,
            on_error: on_error.empty? ? DEFAULT_ON_ERROR : on_error,
            priority: (h["priority"] || DEFAULT_PRIORITY).to_i)
      end

      # A hook known only by its file (no declared event): its sha, the defaults.
      def self.of_file(path)
        new(sha256: "sha256:#{Digest::SHA256.hexdigest(File.binread(path))}")
      end

      # "sha256:<hex>" from either form, "" for none.
      def self.prefixed(sha)
        sha = sha.to_s.strip
        sha.empty? || sha.start_with?("sha256:") ? sha : "sha256:#{sha}"
      end

      # The sha's hex, "" when none is recorded.
      def hex = sha256.delete_prefix("sha256:")

      # The string-keyed form manifest.yml and manifest.json hold.
      def to_record = to_h.transform_keys(&:to_s)
    end
  end
end
