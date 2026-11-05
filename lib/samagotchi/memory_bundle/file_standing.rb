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
      # A real conflict on such a mark: its base can't say what the bundle changed.
      LEGACY_CONFLICT = "it conflicts with the bundle's text, and an older chi's base can't say what it missed"
      # A marked file Remerge leaves for the next upgrade or restore.
      WAITS_FOR_UPGRADE = "it matches its old base, and the bundle's next version replaces it"
      FILE_MISSING = "the file is missing, and the bundle's next version puts it back"
      UNSURE = "an older chi marked it, and the next upgrade checks it"
      NOT_SHIPPED = "not in the bundle now, nothing to merge"

      # What --force does to a file that stays behind, and to an edited one being removed.
      FORCE_TAKES = "--force takes the bundle's version, your file copied to the trash first"
      FORCE_MOVES = "--force moves it to the trash"
      # Why a file an agent step was given stays behind (BundleCommand#settle_conflicts).
      STILL_BEHIND = { untouched: "Nothing changed in %s: still behind.",
                       markers: "%s still holds conflict markers: still behind.",
                       incoming_gone: "The bundle's copy of %s is gone: still behind." }.freeze
      # A chi update row's short word for the trash; the path is long for a table.
      IN_THE_TRASH = "old copies: chi bundle trash"
      # How many missed headings a line names.
      SHOWN_MISSED = 3

      # One file that stays behind. why: the clause saying why no merge was tried
      # (.no_merge, or a plain reason), nil for a real conflict. missed: the
      # headings of the sections the bundle changed. places: the changes under no
      # heading. unsure: an older mark that no retry has looked at, with nothing to
      # compare the file to, so chi can't say it is behind.
      # What a record gives is read as it is shaped: anything else is nothing known.
      Behind = Data.define(:file, :version, :why, :missed, :places, :unsure) do
        def initialize(file:, version: nil, why: nil, missed: [], places: 0, unsure: false)
          super(file: file, version: version, why: why.is_a?(String) ? FileStanding.text(why) : nil,
                missed: (missed.is_a?(Array) ? missed : []).grep(String).map { |heading| FileStanding.text(heading) },
                places: places.is_a?(Integer) && places.positive? ? places : 0, unsure: unsure)
        end

        # "stays behind 0.8.0: missed ## Objectives"
        def state(dry_run: false)
          return "may be behind#{" #{version}" if version}: #{UNSURE}" if unsure

          head = "#{dry_run ? "would stay" : "stays"} behind#{" #{version}" if version}"
          rest = [why, FileStanding.missed_words(missed, places)].compact.join("; ")
          rest.empty? ? head : "#{head}: #{rest}"
        end

        # "x.md stays behind 0.8.0: missed ## Objectives"
        def line(dry_run: false) = "#{FileStanding.text(file)} #{state(dry_run: dry_run)}"
      end

      # A merge no report has shown yet, as the file's record keeps it
      # (Provenance#note_merged). Every merge leaves one: a worker's reaches nothing
      # but its log, an automatic update's rows no person. It shows in chi bundle
      # status while it exists. A report someone reads ends it: chi update's row, for
      # what it printed (this run's merges too), and chi bundle upgrade's output. No
      # start says it: most sessions never read that file.
      MergeNote = Data.define(:file, :version, :at, :trash) do
        # "merged 0.8.0 into your x.md on 2026-11-05 14:03"
        def line
          "#{FileStanding.merged_line([file], version)}#{" on #{FileStanding.local_time(at)}" if at}"
        end
      end

      module_function

      # +value+ as UTF-8, whatever it was tagged, what isn't valid replaced: a file
      # name under LC_ALL=C and a heading must join in one line.
      def text(value) = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub

      # "merged 0.8.0 into your x.md, y.md"
      def merged_line(files, version, dry_run: false)
        "#{dry_run ? "would merge" : "merged"}#{" #{version}" if version} into your #{files.map { |file| text(file) }.join(", ")}"
      end

      # The clause for a merge that couldn't answer: +why+ is TextMerge's reason
      # or LEGACY_BASE, where chi can't even say the file holds edits.
      def no_merge(why)
        why == LEGACY_BASE ? "chi can't tell whether it holds edits of yours (#{why})" : "no merge possible (#{why})"
      end

      def still_behind(reason, file) = format(STILL_BEHIND.fetch(reason), text(file))

      def left_as_it_is(message) = "left as it is (#{message})"

      # "missed ## A, ## B, ## C and 2 more", "missed 2 places"; nil for nothing known.
      def missed_words(headings, places)
        return places.positive? ? "missed #{counted(places, "place")}" : nil if headings.empty?

        more = [headings.size - SHOWN_MISSED, 0].max + places
        words = "missed #{headings.first(SHOWN_MISSED).join(", ")}"
        more.positive? ? "#{words} and #{more} more" : words
      end

      # "1 file behind"; "2 files may be behind" if chi isn't sure of one of them.
      def behind_count(count, unsure: false) = "#{counted(count, "file")} #{"may be " if unsure}behind"

      # "1 file stays behind", "2 files stay behind"; "1 file may be behind"
      def stay_behind(count, unsure: false)
        return behind_count(count, unsure: true) if unsure

        "#{counted(count, "file")} #{count == 1 ? "stays" : "stay"} behind"
      end

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
        behind_lines = behind.map { |file| file.line(dry_run: dry_run) }
        behind_lines[0] += " (#{diff_hint(bundle, behind.first.file)})" unless behind.empty?
        [*(merged.empty? ? nil : merged_line(merged, version, dry_run: dry_run)), *behind_lines, *earlier.map(&:line)]
      end

      def diff_hint(bundle, file) = "chi bundle diff #{text(bundle)} #{text(file)}"

      def local_time(stamp)
        Time.iso8601(stamp.to_s).localtime.strftime("%Y-%m-%d %H:%M")
      rescue ArgumentError
        stamp.to_s
      end

      # The one answer to whether a file stays behind, for a report and a retry
      # alike: marked, there, and not level with the bundle's text the mark speaks
      # of. A missing file is a missing file (a project-scope record doesn't even
      # say which project it means).
      # @param incoming_sha [String, nil] that text's digest, for a mark with none
      def behind?(path, entry, incoming_sha: entry[:incoming_sha])
        entry[:conflict] == true && File.exist?(path) && differs?(path, incoming_sha)
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
