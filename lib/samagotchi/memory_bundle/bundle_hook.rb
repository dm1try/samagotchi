# frozen_string_literal: true

module Samagotchi
  module MemoryBundle
    # One class-file hook's metadata, as an older chi's installed record
    # (manifest.json) keeps it (chi no longer installs or loads them:
    # Manifest::HooksRetired; it reads them to retire, uninstall and name
    # them, and the trash selection takes #sha256): the file's sha256
    # ("sha256:<hex>", "" when none is recorded), the events it registers
    # for (manifest `event:` for one, `events:` a list; none: it isn't
    # loaded), on_error (skip, log or fail_closed) and priority. The one
    # place the defaults live.
    class BundleHook < Data.define(:sha256, :events, :on_error, :priority)
      DEFAULT_ON_ERROR = "skip"
      DEFAULT_PRIORITY = 100

      # @param event [String, nil] one event (manifest `event:`)
      # @param events [Array<String>, String, nil] the events (manifest
      #   `events:`); `event:` and `events:` together are joined, blanks
      #   and repeats dropped
      def initialize(sha256: "", event: nil, events: nil, on_error: DEFAULT_ON_ERROR, priority: DEFAULT_PRIORITY)
        names = [*event, *events].map { |e| e.to_s.strip }.reject(&:empty?).uniq.freeze
        super(sha256: sha256, events: names, on_error: on_error, priority: priority)
      end

      # @param raw [Hash, BundleHook, nil] string keys (manifest.yml) or
      #   symbol keys (a read record); missing or blank values get the
      #   defaults
      def self.parse(raw)
        return raw if raw.is_a?(BundleHook)

        h = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
        on_error = h["on_error"].to_s.strip
        new(sha256: prefixed(h["sha256"]), event: h["event"], events: h["events"],
            on_error: on_error.empty? ? DEFAULT_ON_ERROR : on_error,
            priority: (h["priority"] || DEFAULT_PRIORITY).to_i)
      end

      # "sha256:<hex>" from either form, "" for none.
      def self.prefixed(sha)
        sha = sha.to_s.strip
        sha.empty? || sha.start_with?("sha256:") ? sha : "sha256:#{sha}"
      end
    end
  end
end
