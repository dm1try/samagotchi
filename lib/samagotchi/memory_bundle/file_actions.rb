# frozen_string_literal: true

require_relative "file_state"

module Samagotchi
  module MemoryBundle
    # What each command that acts on a bundle memory does in each FileState:
    # one table per command, so a reader sees one command on one screen. A cell
    # is keyed [kind, mark] or [kind, :any]; a dropped file another bundle
    # lists too is [kind, :shared] (FileState#shared_with, asked only there).
    # A dry run reads its command's row and doesn't execute it.
    #
    # A new kind or a new command adds a row in each table it reaches
    # (docs/internals/bundles.md).
    module FileActions
      # do:         what happens to the file's bytes
      #   :write_incoming  the bundle's text replaces it (or is put there)
      #   :merge           the text merge's result replaces it (Merger::Outcome)
      #   :decide          not a function of kind and mark: the caller asks
      #                    Merger::Upgrade#decision, and FileActions.decided
      #                    turns its Outcome into the action
      #   :keep            left as it is (already the bundle's, or kept)
      #   :skip            left as it is, the bundle doesn't take it
      #   :move_to_trash   moved to the trash (a removal)
      #   :refuse          the command stops
      #   :restore         the bundle's text put back (SystemBundle at its version)
      # save_first: a copy of the old bytes goes to the trash before a write
      #   (when they differ from what is written)
      # next_base:  :on_disk (the file as the command leaves it), :incoming,
      #   :recorded (the base it has; none stays none), :none (no entry left)
      #   -- Merger::Outcome#base's vocabulary
      # word:       the report bucket the file is on (Installer#summary)
      # record:     the entry afterwards: :own (rebuilt, no mark), :keep_entry
      #   (kept with its base, no mark), :mark (marked behind), :hold_mark (as
      #   it was, mark and all), :clear_mark, :drop, :not_owned (never recorded)
      Action = Data.define(:do, :save_first, :next_base, :word, :record) do
        def initialize(do:, word:, next_base: :recorded, record: :own, save_first: false) = super

        # The file stays behind the bundle, marked (a conflict to the report).
        def behind? = record == :mark
      end

      WRITE = Action.new(do: :write_incoming, word: :installed, next_base: :on_disk)
      UP_TO_DATE = Action.new(do: :keep, word: :up_to_date, next_base: :on_disk)
      USER_SAME = Action.new(do: :keep, word: :up_to_date, next_base: :none, record: :not_owned)
      USERS_OWN = Action.new(do: :skip, word: :kept_own, next_base: :none, record: :not_owned)
      KEPT_OWN = Action.new(do: :skip, word: :kept_own, record: :keep_entry)
      HELD = Action.new(do: :skip, word: :kept_own, record: :hold_mark)
      FAST_FORWARD = Action.new(do: :write_incoming, word: :updated, next_base: :on_disk)
      KEEP = Action.new(do: :keep, word: :kept)
      # No base: no merge is possible, so the file stays behind, marked.
      BEHIND = Action.new(do: :keep, word: :behind, record: :mark)
      DECIDE = Action.new(do: :decide, word: nil)
      REFUSE = Action.new(do: :refuse, word: nil, record: :hold_mark)
      FORCED = Action.new(do: :write_incoming, word: :installed, next_base: :on_disk, save_first: true)
      # The bundle dropped it: a plain install keeps it and its entry (the
      # upgrade it points at moves it), an upgrade moves it unless edited.
      DROPPED_KEPT = Action.new(do: :keep, word: nil, record: :keep_entry)
      DROPPED_GONE = Action.new(do: :skip, word: nil, next_base: :none, record: :drop)
      REMOVE = Action.new(do: :move_to_trash, word: :removed, next_base: :none, record: :drop)
      KEPT_PRUNED = Action.new(do: :keep, word: :kept_pruned, record: :keep_entry)
      KEPT_SHARED = Action.new(do: :keep, word: :kept_shared, next_base: :none, record: :drop)

      # Rows every installing command shares: files the bundle doesn't own.
      NOT_OWNED = {
        %i[new any] => WRITE, %i[user_same any] => USER_SAME, %i[user_file any] => USERS_OWN,
        %i[missing any] => WRITE, %i[level any] => UP_TO_DATE, %i[unreadable any] => REFUSE
      }.freeze

      # A plain install (a re-install over the record, or a fresh one).
      INSTALL = NOT_OWNED.merge(
        # A file never edited takes the source's text, as an upgrade's
        # fast-forward does (D4); an edited one stays (an upgrade merges it).
        %i[pristine none] => FAST_FORWARD, %i[pristine_no_base none] => FAST_FORWARD,
        %i[edited none] => KEPT_OWN, %i[diverged none] => KEPT_OWN, %i[edited_no_base none] => KEPT_OWN,
        # A marked file it skips has missed the bundle's change as much as before.
        %i[pristine any] => HELD, %i[edited any] => HELD, %i[diverged any] => HELD,
        %i[pristine_no_base any] => HELD, %i[edited_no_base any] => HELD,
        %i[dropped_pristine any] => DROPPED_KEPT, %i[dropped_edited any] => DROPPED_KEPT,
        %i[dropped_missing any] => DROPPED_GONE
      ).freeze

      # install --force and upgrade --force: the bundle's text everywhere, an
      # edit copied to the trash first. Its dropped rows are upgrade --force's
      # (a plain install --force never prunes: its dropped files are INSTALL's).
      FORCE = NOT_OWNED.merge(
        # A file that already has the bundle's text is written all the same
        # (nothing to save): it is installed, and checked, as any other.
        %i[new any] => FORCED, %i[user_same any] => FORCED, %i[user_file any] => FORCED, %i[level any] => FORCED,
        %i[pristine any] => FORCED, %i[edited any] => FORCED, %i[diverged any] => FORCED,
        %i[pristine_no_base any] => FORCED, %i[edited_no_base any] => FORCED,
        %i[dropped_pristine any] => REMOVE, %i[dropped_edited any] => REMOVE, %i[dropped_missing any] => DROPPED_GONE,
        %i[dropped_pristine shared] => KEPT_SHARED, %i[dropped_edited shared] => KEPT_SHARED
      ).freeze

      # An upgrade's 3-way view (Merger::Upgrade#outcome).
      UPGRADE = NOT_OWNED.merge(
        %i[pristine none] => FAST_FORWARD,
        # A marked file that equals its base takes the update; a copy is kept.
        %i[pristine current] => FAST_FORWARD.with(save_first: true),
        # An older chi's mark: fast-forward unless it takes a line out and
        # ShippedHistory can't prove the base (the legacy guard).
        %i[pristine legacy] => DECIDE,
        %i[edited any] => KEEP,
        # The text merge: merged, a conflict, or already merged.
        %i[diverged any] => DECIDE,
        %i[pristine_no_base any] => BEHIND, %i[edited_no_base any] => BEHIND,
        %i[dropped_pristine any] => REMOVE, %i[dropped_edited any] => KEPT_PRUNED, %i[dropped_missing any] => DROPPED_GONE,
        %i[dropped_pristine shared] => KEPT_SHARED, %i[dropped_edited shared] => KEPT_SHARED
      ).freeze

      # Remerge: the retry of a marked file at the same version. Unmarked
      # files are never asked. Before the table, a mark whose source moved
      # stays behind as it is (FileState#source_moved?).
      REMERGE = {
        %i[level any] => Action.new(do: :keep, word: :settled, next_base: :on_disk, record: :clear_mark),
        %i[edited any] => Action.new(do: :keep, word: :settled, record: :clear_mark),
        %i[diverged any] => DECIDE,
        # It matches its old base: the next upgrade takes the update.
        %i[pristine current] => BEHIND,
        %i[pristine legacy] => DECIDE,
        %i[pristine_no_base any] => BEHIND, %i[edited_no_base any] => BEHIND,
        # Not shipped now: behind, nothing to merge.
        %i[dropped_pristine any] => BEHIND, %i[dropped_edited any] => BEHIND,
        %i[dropped_missing any] => Action.new(do: :skip, word: nil, record: :hold_mark),
        # The next upgrade or a restore puts it back.
        %i[missing any] => Action.new(do: :skip, word: nil, record: :hold_mark),
        %i[unreadable any] => Action.new(do: :keep, word: :behind, record: :hold_mark)
      }.freeze

      # SystemBundle at its version: a memory not on disk is put back, one the
      # record doesn't own too (research Q2, today's behaviour).
      RESTORE = {
        %i[missing any] => Action.new(do: :restore, word: :restored, next_base: :on_disk),
        %i[new any] => Action.new(do: :restore, word: :restored, next_base: :on_disk)
      }.freeze

      # Uninstall, on the source-less kinds: an edit refuses (Uninstaller's
      # --force moves it instead); a file another bundle lists stays.
      UNINSTALL = {
        %i[pristine any] => REMOVE, %i[pristine_no_base any] => REMOVE,
        %i[edited any] => REFUSE, %i[edited_no_base any] => REFUSE, %i[unreadable any] => REFUSE,
        %i[missing any] => DROPPED_GONE,
        %i[pristine shared] => KEPT_SHARED, %i[pristine_no_base shared] => KEPT_SHARED,
        %i[edited shared] => KEPT_SHARED, %i[edited_no_base shared] => KEPT_SHARED
      }.freeze

      TABLES = { install: INSTALL, force: FORCE, upgrade: UPGRADE, remerge: REMERGE, restore: RESTORE,
                 uninstall: UNINSTALL }.freeze
      # The kinds whose row depends on another bundle listing the file.
      SHARED_ASKED = %i[dropped_pristine dropped_edited pristine pristine_no_base edited edited_no_base].freeze

      # The command's action for +state+: [kind, :shared] when another bundle
      # lists a file that has such a row, else [kind, mark], then [kind, :any].
      # @param command [Symbol] a TABLES key
      # @return [Action, nil] nil: the command never meets the state
      def self.for(command, state)
        table = TABLES.fetch(command)
        if SHARED_ASKED.include?(state.kind) && table.key?([state.kind, :shared]) && state.shared_with.any?
          return table.fetch([state.kind, :shared])
        end

        table[[state.kind, state.mark]] || table[[state.kind, :any]]
      end

      # A :decide cell's answer: the action Merger::Upgrade#decision's Outcome
      # stands for. Remerge never fast-forwards (the next upgrade does) and
      # settles a file with nothing left to miss.
      # @param outcome [Merger::Outcome]
      # @param command [Symbol] :upgrade or :remerge
      def self.decided(outcome, command = :upgrade)
        case outcome.status
        when :merged then Action.new(do: :merge, word: :merged, next_base: :incoming, save_first: true)
        when :conflict then BEHIND
        when :fast_forward then command == :remerge ? BEHIND : FAST_FORWARD.with(save_first: true)
        when :keep, :noop
          command == :remerge ? Action.new(do: :keep, word: :settled, next_base: outcome.base, record: :clear_mark) : KEEP.with(next_base: outcome.base)
        else raise ArgumentError, "no action for outcome #{outcome.status.inspect}"
        end
      end
    end
  end
end
