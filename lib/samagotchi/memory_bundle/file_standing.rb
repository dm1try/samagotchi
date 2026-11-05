# frozen_string_literal: true

require "digest"
require "time"

module Samagotchi
  module MemoryBundle
    # What chi says of an edited bundle file, everywhere it reports one: the one
    # owner of these words (chi update's row and --json, chi bundle list and
    # status, chi self, chi bootstrap, SystemBundle.ensure!'s echo, the Installer's
    # summary, the phone's push).
    #
    # A file is merged (it took the update) or behind: marked conflict on its
    # record, with bytes other than the bundle's text it speaks of. A marked file
    # brought level by hand isn't behind, and a missing one is a missing file.
    module FileStanding
      # Why a merge of a mark from an older chi didn't go ahead (Merger.merge_outcome).
      LEGACY_BASE = "an older chi may have taken your text as the base, and the merge would remove lines from your file"
      # A marked file Remerge leaves for the next upgrade or restore.
      WAITS_FOR_UPGRADE = "it matches its old base, and the bundle's next version replaces it"
      FILE_MISSING = "the file is missing, and the bundle's next version puts it back"
      NOT_SHIPPED = "not in the bundle now, nothing to merge"

      # What --force does to a file that stays behind.
      FORCE_TAKES = "--force takes the bundle's version, your file copied to the trash first"
      # A chi update row's short word for the trash; the path is long for a table.
      IN_THE_TRASH = "old copies: chi bundle trash"
      # How many missed headings a line names.
      SHOWN_MISSED = 3

      # One file that stays behind. why: the clause saying why no merge was tried
      # (.no_merge, or a plain reason), nil for a real conflict. missed: the
      # headings of the sections the bundle changed. places: the changes under no
      # heading.
      Behind = Data.define(:file, :version, :why, :missed, :places) do
        def initialize(file:, version: nil, why: nil, missed: [], places: 0)
          super(file: file, version: version, why: why, missed: Array(missed), places: places.to_i)
        end

        # "stays behind 0.8.0: missed ## Objectives"
        def state(dry_run: false)
          head = "#{dry_run ? "would stay" : "stays"} behind#{" #{version}" if version}"
          rest = [why, FileStanding.missed_words(missed, places)].compact.join("; ")
          rest.empty? ? head : "#{head}: #{rest}"
        end

        # "x.md stays behind 0.8.0: missed ## Objectives"
        def line(dry_run: false) = "#{file} #{state(dry_run: dry_run)}"
      end

      # A merge no report has shown yet, as the file's record keeps it
      # (Provenance#note_merged). It shows in chi bundle status and in the next
      # chi update, whose row is its last appearance.
      MergeNote = Data.define(:file, :version, :at, :trash) do
        # "merged 0.8.0 into your x.md on 2026-11-05 14:03"
        def line
          "#{FileStanding.merged_line([file], version)}#{" on #{FileStanding.local_time(at)}" if at}"
        end
      end

      module_function

      # "merged 0.8.0 into your x.md, y.md"
      def merged_line(files, version, dry_run: false)
        "#{dry_run ? "would merge" : "merged"}#{" #{version}" if version} into your #{files.join(", ")}"
      end

      # The clause for a merge that couldn't answer: +why+ is TextMerge's reason
      # or LEGACY_BASE, where chi can't even say the file holds edits.
      def no_merge(why)
        why == LEGACY_BASE ? "chi can't tell whether it holds edits of yours (#{why})" : "no merge possible (#{why})"
      end

      def left_as_it_is(message) = "left as it is (#{message})"

      # "missed ## A, ## B, ## C and 2 more", "missed 2 places"; nil for nothing known.
      def missed_words(headings, places)
        return places.positive? ? "missed #{counted(places, "place")}" : nil if headings.empty?

        more = headings.size - SHOWN_MISSED + places
        words = "missed #{headings.first(SHOWN_MISSED).join(", ")}"
        more.positive? ? "#{words} and #{more} more" : words
      end

      # "1 file behind"
      def behind_count(count) = "#{counted(count, "file")} behind"

      # "1 file stays behind", "2 files stay behind"
      def stay_behind(count) = "#{counted(count, "file")} #{count == 1 ? "stays" : "stay"} behind"

      # The sentence of a push, merged and behind as counts: "" for neither.
      def counts_sentence(merged:, behind:)
        parts = []
        parts << "Merged the update into #{counted(merged, "file")} you edited." if merged.to_i.positive?
        parts << "#{stay_behind(behind)}." if behind.to_i.positive?
        parts.join(" ")
      end

      # A report's clauses for one bundle: what merged, what stays behind with
      # how to see it, what an earlier merge did.
      # @param merged [Array<String>] files
      # @param behind [Array<Behind>]
      # @param earlier [Array<MergeNote>]
      # @return [Array<String>]
      def clauses(bundle, version, merged: [], behind: [], earlier: [], dry_run: false)
        lines = merged.empty? ? [] : [merged_line(merged, version, dry_run: dry_run)]
        lines.concat(behind.map { |file| file.line(dry_run: dry_run) })
        lines[-1] += " (#{diff_hint(bundle, behind.first.file)})" unless behind.empty?
        lines + earlier.map(&:line)
      end

      def diff_hint(bundle, file) = "chi bundle diff #{bundle} #{file}"

      def local_time(stamp)
        Time.iso8601(stamp.to_s).localtime.strftime("%Y-%m-%d %H:%M")
      rescue ArgumentError
        stamp.to_s
      end

      # The file's bytes aren't what the mark says the bundle ships. One it can't
      # read isn't known to be level. No digest (an older mark): it isn't known
      # either, and a retry would have settled it.
      def differs?(path, incoming_sha)
        incoming_sha.nil? || Digest::SHA256.file(path).hexdigest != incoming_sha
      rescue SystemCallError
        true
      end

      def counted(count, noun) = "#{count} #{noun}#{"s" unless count == 1}"
    end
  end
end
