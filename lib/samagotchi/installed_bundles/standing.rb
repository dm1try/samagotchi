# frozen_string_literal: true

module Samagotchi
  autoload :Log, File.expand_path("../log", __dir__)

  module InstalledBundles
    # Why chi won't use an installed bundle, or one of its files: the verdict's
    # answer, which each reader reacts to in its own way (fail closed, a note,
    # a log line once, a skip).
    #   kind      :unreadable (the record: manifest.json doesn't read),
    #             :too_new (its requires_chi isn't met), or for one file
    #             (Dir#file_refusal) :file_missing, :file_unrecorded (no
    #             sha256 recorded for it), :file_changed; for a plugin
    #             (Dir#plugin_refusal) also :parts_missing (its kept manifest
    #             names parts the record has none of)
    #   text      what the reader says of it today (one wording per kind of
    #             file: the plugin's, a script's, a rule's)
    #   actual, expected  the file's sha256 and the recorded one, hex, for
    #             :file_changed; nil otherwise
    Refusal = Data.define(:kind, :text, :actual, :expected) do
      def initialize(kind:, text:, actual: nil, expected: nil) = super
    end

    # The [bundle, reason] pairs Standing.warn_unreadable has logged.
    UNREADABLE_WARNED = Set.new
    UNREADABLE_LOCK = Mutex.new

    # One installed bundle as the verdict sees it, before any of its files is
    # looked at: its record (one with error set when it doesn't read) and why
    # chi won't use it, nil when it may.
    Standing = Data.define(:name, :record, :refusal) do
      # The bundle-level gate, on a record already read: an unreadable record
      # (warned of once, .warn_unreadable), then requires_chi. Reads the
      # record's manifest (cached); a cache miss hashes the kept manifest.yml
      # (Manifest.of), and no other file.
      # @param record [Record]
      # @return [Standing]
      def self.of(name, record)
        refusal = if record.error?
                    warn_unreadable(name, record.error)
                    Refusal.new(kind: :unreadable, text: record.error)
                  elsif (failure = record.manifest.requires_chi_failure)
                    Refusal.new(kind: :too_new, text: failure)
                  end
        new(name: name, record: record, refusal: refusal)
      end

      # A record that doesn't read, said in the log once per process per
      # bundle (and reason), whichever reader came across it: most readers
      # only skip it (providers, renderers, settings, needs, memory owners).
      def self.warn_unreadable(name, text)
        return unless UNREADABLE_LOCK.synchronize { UNREADABLE_WARNED.add?([name, text]) }

        Log.warn(:memory, "bundle_unreadable", bundle: name, msg: text)
      end

      # Forget what was warned of (specs).
      def self.reset_warnings! = UNREADABLE_LOCK.synchronize { UNREADABLE_WARNED.clear }

      def usable? = refusal.nil?

      def unreadable? = refusal&.kind == :unreadable

      def too_new? = refusal&.kind == :too_new
    end
  end
end
