# frozen_string_literal: true

require "digest"
require_relative "../atomic_file"
require_relative "file_digest"
require_relative "installed_bundle"
require_relative "file_actions"

module Samagotchi
  module MemoryBundle
    # Most processes that load this never merge.
    autoload :TextMerge, File.expand_path("text_merge", __dir__)
    autoload :ShippedHistory, File.expand_path("shipped_history", __dir__)

    # 3-way merge helper for bundle upgrades.
    #
    # An upgrade's merge: what FileState and FileActions' UPGRADE table say of
    # a file, as an Outcome, and the text merge where both sides changed it.
    module Merger
      # What an upgrade does to one file. status names the case; base is where
      # the file's next base comes from:
      #   :on_disk   the file as the install leaves it: it took the bundle's
      #              bytes, or already had them.
      #   :recorded  the base it has (none stays none): the file stays as the
      #              user has it, and the next upgrade must still see the edit.
      #   :incoming  the bundle's new file: a merged file keeps the user's
      #              edits, so it must never become the base (the edit is what
      #              differs from the base, and the next upgrade would
      #              fast-forward over it).
      # The same words as FileActions::Action#next_base: an Outcome is what an
      # UPGRADE cell stands for to a plan, and a :decide cell's answer.
      #
      # merge is Upgrade#outcome's TextMerge::Result, so a merge runs git once
      # and its answer travels with the outcome: a :merged outcome's text, a
      # :conflict's why (nil for a real one). current_sha is the digest of the
      # file that merge read: write_merged checks it. The constants leave both nil.
      Outcome = Data.define(:status, :base, :merge, :current_sha) do
        def initialize(status:, base:, merge: nil, current_sha: nil) = super

        def conflict? = status == :conflict

        def merged? = status == :merged

        # Why no merge was possible, nil when one wasn't tried or it found a
        # real conflict.
        def why = merge&.why
      end

      INSTALL = Outcome.new(status: :install, base: :on_disk)
      FAST_FORWARD = Outcome.new(status: :fast_forward, base: :on_disk)
      NOOP = Outcome.new(status: :noop, base: :on_disk)
      KEEP = Outcome.new(status: :keep, base: :recorded)
      CONFLICT = Outcome.new(status: :conflict, base: :recorded)
      # Nothing to take: the bundle has no such file, so whatever is on disk
      # (the user's text, perhaps) must not become the base. A noop to callers.
      NO_INCOMING = Outcome.new(status: :noop, base: :recorded)
      # Both changed it, and the text merge adds nothing: the user's file already
      # has what the bundle brings. Kept, but the base moves on. (Upgrade#outcome)
      ALREADY_MERGED = Outcome.new(status: :keep, base: :incoming)

      # What an upgrade would do to the files asked about, by what callers say
      # of them. merged: file names; behind: FileStanding::Behind.
      Forecast = Data.define(:merged, :behind) do
        def conflicts = behind.map(&:file)
      end

      # One file's upgrade, read once (Upgrade#decision): its FileState, the
      # action the upgrade takes (a :decide cell already answered) and the
      # Outcome that action stands for.
      Decision = Data.define(:state, :action, :outcome)

      # One bundle's upgrade as seen before it runs: what it does to a file,
      # nothing written. The one way to ask: Installer's merge and dry run,
      # ShippedUpdate's plan and SystemBundle's dry run. Which files to ask
      # about is the caller's, and they differ (see #forecast).
      Upgrade = Data.define(:provenance, :target_dir, :source_dir) do
        # What the upgrade does to the file, with what it was read from: its
        # FileState, the UPGRADE action (a :decide cell answered by #outcome's
        # merge or legacy guard, through FileActions.decided) and the Outcome.
        # @return [Decision]
        def decision(file_key)
          state = state(file_key)
          action = FileActions.for(:upgrade, state)
          outcome = outcome_of(file_key, state, action)
          Decision.new(state: state, action: action.do == :decide ? FileActions.decided(outcome) : action, outcome: outcome)
        end

        # What the upgrade does to the file: its FileState's UPGRADE cell, and
        # where both sides changed it, the text merge (git runs here, once per
        # call). A mark from an older chi fast-forwards only if no line of the
        # file goes or its base is proved: see .merge_outcome.
        # @return [Outcome]
        def outcome(file_key) = decision(file_key).outcome

        # The file as the upgrade meets it (FileState, with the source).
        # @return [FileState]
        def state(file_key)
          FileState.of(file_key, record: provenance.record, provenance: provenance, target_dir: target_dir, source_dir: source_dir)
        end

        # The ones among +file_keys+ that would merge or end in a conflict. The
        # Installer's own list is MemoryFiles.select, and a plan may ask about
        # others: ShippedUpdate about every *.md shipped, SystemBundle about the
        # manifest's files:. So a plan can name a file the upgrade itself
        # doesn't merge (docs/internals/bundles.md).
        # @param version [String, nil] the version it would bring
        # @return [Forecast]
        def forecast(file_keys, version: nil)
          outcomes = file_keys.to_h { |key| [key, outcome(key)] }
          Forecast.new(merged: outcomes.select { |_, o| o.merged? }.keys,
                       behind: outcomes.select { |_, o| o.conflict? }.map { |key, o| behind(key, o, version) })
        end

        # A :conflict outcome as a report and the mark read it: why no merge was
        # possible, and what the bundle changed that the file doesn't get. A base
        # that may be the user's own text (an older mark) can't say what changed.
        # @param version [String, nil] the version the file stays behind
        # @return [FileStanding::Behind]
        def behind(file_key, outcome, version)
          why = outcome.why && FileStanding.no_merge(outcome.why)
          base = paths(file_key)[:base]
          if InstalledBundle.legacy_mark?(provenance.record&.files&.fetch(file_key, nil))
            return FileStanding::Behind.new(file: file_key, version: version, why: why || FileStanding::LEGACY_CONFLICT)
          end
          return FileStanding::Behind.new(file: file_key, version: version, why: why) unless File.exist?(base)

          sides = paths(file_key)
          headings, unnamed = TextMerge.changed_sections(File.binread(base), File.binread(sides[:incoming]), File.binread(sides[:current]))
          # Only the places under no heading: the others are named.
          places = unnamed ? [outcome.merge&.hunks&.count { |hunk| !hunk.union? && hunk.heading.nil? }.to_i, 1].max : 0
          FileStanding::Behind.new(file: file_key, version: version, why: why, missed: headings, places: places)
        end

        # @return [Hash{Symbol => String}] the file's :base, :current, :incoming
        def paths(file_key)
          { base: provenance.base_path(file_key), current: File.join(target_dir, file_key),
            incoming: File.join(source_dir, file_key) }
        end

        private

        # The Outcome a cell stands for; a :decide cell's is the text merge
        # (:diverged) or the legacy guard ([:pristine, :legacy]).
        def outcome_of(file_key, state, action)
          return NO_INCOMING if state.digests.incoming.nil?

          case action.do
          when :decide then decide(file_key, state)
          when :write_incoming then action.word == :installed ? INSTALL : FAST_FORWARD
          when :keep
            return no_base if action.behind?

            action.word == :kept ? KEEP : NOOP
          # A file the bundle doesn't own, the user's: there is no base to merge from.
          when :skip then no_base
          # It can't be read: the read raises, as the merge would.
          when :refuse then FileDigest.hex(paths(file_key)[:current])
          else raise ArgumentError, "no outcome for #{action.do.inspect} (#{file_key})"
          end
        end

        # No base, no merge: the file stays behind (TextMerge::NO_BASE says why).
        def no_base = CONFLICT.with(merge: TextMerge.failed(TextMerge::NO_BASE))

        def decide(file_key, state)
          # Asked only when the guard would otherwise fire.
          unproved = -> { state.mark == :legacy && !ShippedHistory.shipped?(provenance.name, file_key, paths(file_key)[:base]) }
          return Merger.merge_outcome(paths(file_key), unproved: unproved) unless state.kind == :pristine

          # The guard's own case at its plainest: the file is the base, which
          # may be the user's text. One that only gains lines loses nothing, and
          # save_marked_file keeps a copy.
          sides = paths(file_key)
          return FAST_FORWARD unless Merger.removes_lines?(File.binread(sides[:current]), File.binread(sides[:incoming]))

          unproved.call ? CONFLICT.with(merge: TextMerge.failed(FileStanding::LEGACY_BASE)) : FAST_FORWARD
        end
      end

      # Both sides changed the file: the text merge's answer as an Outcome. No
      # base means no merge: the file stays as a conflict.
      #
      # unproved: the file's mark may be 0.149's, whose base can be the user's own
      # text. Merging against it reads the bundle's text as undoing that text,
      # with no conflict to show for it, so a merge that would take any line out
      # of the file stays a conflict, and so does such a fast-forward (Upgrade#outcome).
      # A base some installed chi shipped can't be the user's text
      # (ShippedHistory), and a mark from this chi has a real base: a merge there
      # may take what the bundle removed. With no such gem left, a real base
      # looks the same, and the file stays behind.
      # @param sides [Hash{Symbol => String}] Upgrade#paths
      # @param unproved [#call] whether the base may be the user's text; called
      #   only when the merge would take a line out
      # @return [Outcome]
      def self.merge_outcome(sides, unproved: -> { false })
        unless sides[:base] && File.exist?(sides[:base])
          return CONFLICT.with(merge: TextMerge.failed(TextMerge::NO_BASE))
        end

        ours = File.binread(sides[:current])
        result = TextMerge.merge(base: File.binread(sides[:base]), ours: ours, theirs: File.binread(sides[:incoming]))
        return CONFLICT.with(merge: result) unless result.clean?
        return ALREADY_MERGED if result.text.b == ours.b
        return CONFLICT.with(merge: TextMerge.failed(FileStanding::LEGACY_BASE)) if removes_lines?(ours, result.text) && unproved.call

        Outcome.new(status: :merged, base: :incoming, merge: result, current_sha: Digest::SHA256.hexdigest(ours))
      end

      # Whether +merged+ holds fewer copies of any line of +ours+.
      def self.removes_lines?(ours, merged)
        kept = merged.b.each_line.map(&:chomp).tally
        ours.b.each_line.map(&:chomp).tally.any? { |line, count| kept.fetch(line, 0) < count }
      end

      # A :merged outcome's text goes in +path+, unless the file changed since
      # the merge read it (a live memory_write): a last check just before the
      # rename, so that write isn't lost. Through a symlink, its mode kept, the
      # old file copied to +trash+ first.
      # @return [Boolean] false: the file changed, nothing was replaced
      def self.write_merged(path, outcome, trash)
        return false unless digest(path) == outcome.current_sha

        real = File.realpath(path)
        trash.copy(path)
        AtomicFile.write(real, outcome.merge.text, perm: File.stat(real).mode & 0o7777) do
          raise ChangedDuringMerge unless digest(real) == outcome.current_sha
        end
        true
      rescue ChangedDuringMerge
        false
      end

      class ChangedDuringMerge < StandardError
      end
      private_constant :ChangedDuringMerge

      # A line a merge tool leaves around a conflict. "=======" isn't one: it
      # is also a Markdown heading's underline.
      CONFLICT_MARKER = /^(?:<{7}|>{7})(?: |$)/

      # Whether the file holds a merge's conflict markers.
      def self.markers?(path)
        File.exist?(path) && File.binread(path).match?(CONFLICT_MARKER)
      end

      # The file's digest, nil when there is none.
      def self.digest(path)
        FileDigest.hex(path)
      end
    end
  end
end
