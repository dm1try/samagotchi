# frozen_string_literal: true

require_relative "file_digest"
require_relative "installed_bundle"
require_relative "provenance"

module Samagotchi
  module MemoryBundle
    # One bundle memory as a command meets it: which of a few states it is in,
    # computed once from the file (D), its base (B), the bundle's text (I) and
    # the record's entry (R). Derived, never stored. FileActions says what each
    # acting command does in each state.
    #
    # kind, with a source (install, upgrade, remerge, restore, plan):
    #   :new               not the bundle's, not on disk
    #   :user_same         not the bundle's, on disk with I's bytes
    #   :user_file         not the bundle's, other bytes (the user's own file)
    #   :missing           the bundle's, not on disk
    #   :level             the bundle's, D == I
    #   :pristine          D == B: the bundle's text as installed
    #   :edited            D != B, I == B: the user changed it, the bundle didn't
    #   :diverged          D != B, I != B: both changed it
    #   :pristine_no_base  no B, never edited (D == R's checksum)
    #   :edited_no_base    no B, edited (or no checksum to tell)
    #   :dropped_pristine / :dropped_edited / :dropped_missing  the bundle no
    #                      longer ships it (no I): unedited, edited, gone
    #   :unreadable        on disk, but it can't be read
    # With a base, the kinds read B as Merger always has (an upgrade
    # fast-forwards a file that equals its base); without one, and for a
    # dropped file, the one edited rule (#edited?, the checksum first) says.
    #
    # kind, with no source (status, uninstall, diff): I is unknown, so only
    # :pristine :edited :pristine_no_base :edited_no_base :missing :unreadable,
    # from #edited? alone.
    #
    # mark: :none, :current (a mark this chi wrote) or :legacy (an older
    # chi's, InstalledBundle.legacy_mark?).
    FileState = Data.define(:key, :kind, :mark, :digests, :entry, :paths, :claimants) do
      # Provenance.unchanged?'s answer negated: the one edited rule (checksum
      # first, then the base). A file it can't read counts as edited.
      def edited?
        return false if entry.nil?

        !Provenance.unchanged?(paths[:current], entry, paths[:base])
      rescue SystemCallError
        true
      end

      def marked? = mark != :none

      # A marked file whose source moved since the mark: the mark speaks of
      # other text than the bundle ships now (Remerge's first question). A mark
      # that names no text (an older chi's) never moved.
      def source_moved?
        marked? && !digests.marked_incoming.nil? && !digests.incoming.nil? && digests.marked_incoming != digests.incoming
      end

      # The other installed bundles that list the file too. Asked lazily: only
      # a dropped file and an uninstall need it (Provenance.claimants reads
      # every record).
      def shared_with = claimants.call
    end

    # The digests of the file's texts, each read once: disk (:unreadable when
    # it can't be read), base, incoming (nil with no source), the record's
    # checksum, and the text a mark speaks of (nil without a mark or for an
    # older chi's mark).
    FileState::Digests = Data.define(:disk, :base, :incoming, :recorded, :marked_incoming)

    class << FileState
      # @param record [InstalledBundle, nil] the bundle's record
      # @param provenance [Provenance] the record's (for the base path)
      # @param source_dir [String, nil] the bundle's incoming dir; nil: the
      #   source-less kinds
      # @param claimants [#call, nil] key => other bundles listing it
      #   (Provenance.claimants), called at most once
      # @return [FileState]
      def of(key, record:, provenance:, target_dir:, source_dir:, claimants: nil)
        entry = record&.files&.fetch(key, nil)
        paths = { base: provenance.base_path(key), current: File.join(target_dir, key),
                  incoming: source_dir && File.join(source_dir, key) }
        mark = mark_of(entry)
        digests = FileState::Digests.new(
          disk: digest(paths[:current]), base: entry ? digest(paths[:base]) : nil,
          incoming: source_dir ? digest(paths[:incoming]) : nil, recorded: entry && Provenance.recorded_sha(entry[:checksum]),
          marked_incoming: mark == :none ? nil : entry[:incoming_sha]
        )
        shared = nil
        lookup = -> { shared ||= claimants ? claimants.call(key) : [] }
        state = FileState.new(key: key, kind: nil, mark: mark, digests: digests, entry: entry, paths: paths, claimants: lookup)
        state.with(kind: source_dir ? kind_with_source(state) : kind_without_source(state))
      end

      private

      def mark_of(entry)
        return :none unless entry && entry[:conflict]

        InstalledBundle.legacy_mark?(entry) ? :legacy : :current
      end

      def digest(path)
        FileDigest.hex(path)
      rescue SystemCallError
        :unreadable
      end

      def kind_with_source(state)
        d = state.digests
        return not_owned(d) unless state.entry
        return :unreadable if d.disk == :unreadable
        return dropped(state) if d.incoming.nil?
        return :missing if d.disk.nil?
        return :level if d.disk == d.incoming
        return state.edited? ? :edited_no_base : :pristine_no_base if d.base.nil?
        return :pristine if d.disk == d.base

        d.incoming == d.base ? :edited : :diverged
      end

      def kind_without_source(state)
        d = state.digests
        return :unreadable if d.disk == :unreadable
        return :missing if d.disk.nil?
        return state.edited? ? :edited_no_base : :pristine_no_base if d.base.nil?

        state.edited? ? :edited : :pristine
      end

      def not_owned(digests)
        return :new if digests.disk.nil?

        digests.disk == digests.incoming ? :user_same : :user_file
      end

      def dropped(state)
        return :dropped_missing if state.digests.disk.nil?

        state.edited? ? :dropped_edited : :dropped_pristine
      end
    end
  end
end
