# frozen_string_literal: true

require "digest"

module Samagotchi
  module MemoryBundle
    # One hook's metadata, as a bundle's manifest.yml declares it and its
    # installed record (manifest.json) keeps it: the file's sha256
    # ("sha256:<hex>", "" when none is recorded), the events it registers
    # for (manifest `event:` for one, `events:` a list; none: it isn't
    # loaded), on_error (skip, log or fail_closed) and priority. One
    # instance of the hook serves every event it lists. The one place the
    # defaults live.
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

      # Whether the hook fails closed: on_error fail_closed applies to its
      # before_tool_call registration only.
      def fail_closed?(event) = on_error == "fail_closed" && event.to_s == "before_tool_call"

      # How `chi bundle status` / `diff` name its events: `event=x`, or
      # `events=x,y` for more than one.
      def events_field = events.size > 1 ? "events=#{events.join(",")}" : "event=#{events.first}"

      # The string-keyed form manifest.yml and manifest.json hold: `event`
      # for one event (as an older chi reads it), `events` for more.
      def to_record
        listed = events.size > 1 ? { "events" => events.dup } : { "event" => events.first.to_s }
        { "sha256" => sha256, **listed, "on_error" => on_error, "priority" => priority }
      end
    end
  end
end
