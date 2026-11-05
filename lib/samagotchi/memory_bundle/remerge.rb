# frozen_string_literal: true

require_relative "index_updater"
require_relative "file_standing"
require_relative "manifest"
require_relative "memory_files"
require_relative "merger"
require_relative "provenance"
require_relative "trash"
require_relative "../model_overlay"

module Samagotchi
  module MemoryBundle
    # The retry at the same version, memory files only: nothing else would come
    # back to a file marked conflict until the bundle's next version. It merges
    # what merges and settles those entries, leaving version, installed_at and
    # the assets alone. Not the Installer: that rm_rfs guardrails, plugin and
    # scripts, and GuardrailWiring#rules stats per tool call, so a live session
    # could hit a transient deny.
    #
    # Each marked file, by what Merger::Upgrade says of it:
    #   - not shipped now: its mark, base and text stay, and it reads as behind;
    #   - the shipped text isn't the one the mark names (a checkout at the same
    #     VERSION can carry other text): left alone, behind as its mark says. A
    #     mark that names none (older chi) is tried too, the migration; a real
    #     conflict then records the digest and legacy_base, so
    #     Merger.merge_outcome keeps protecting its file (a merge there may not
    #     take a line out). A mark whose digest matches is tried on every run,
    #     since the user's file or git may have changed;
    #   - merged: replaced as the Installer does, base the incoming file;
    #   - noop, keep (a merge that adds nothing too): the file has nothing left
    #     to miss, so the mark goes;
    #   - conflict: behind, and the mark records why, only when that changed;
    #   - fast_forward (one Merger::Upgrade#outcome lets go ahead), install: the
    #     next upgrade's (save_marked_file, a restore), behind until then;
    #   - one it can't read or replace: left as it is, behind, saying why.
    #
    # It can't loop: settling clears the mark, and a real conflict writes nothing.
    # git runs once per marked file per run, and only for a marked file. A run
    # is every chi start for the system bundle (SystemBundle.ensure!) and `chi
    # update` for it and the other bundles chi ships; a bundle chi doesn't ship
    # gets no Remerge, and `chi bundle upgrade` is its retry.
    class Remerge
      # merged: replaced (or, in a dry run, would be). settled: their mark gone
      # with no merge. stamped: their mark was updated. behind: each file that
      # stays behind, and why (FileStanding::Behind). work? says whether a real run
      # would change anything.
      Result = Data.define(:merged, :settled, :stamped, :behind, :warnings, :trash_copy, :trash_dir) do
        def work? = [merged, settled, stamped].any?(&:any?)
      end
      NOTHING = Result.new(merged: [], settled: [], stamped: [], behind: [], warnings: [], trash_copy: nil, trash_dir: nil).freeze

      # @param record [InstalledBundle, nil] the bundle's record (read when not given)
      def initialize(name:, scope:, target_dir:, source_dir:, record: nil)
        @name = name
        @scope = scope
        @target_dir = target_dir
        @source_dir = source_dir
        @provenance = Provenance.new(name: name)
        @record = record || @provenance.record
      end

      # @param dry_run [Boolean] answer, writing nothing
      # @return [Result]
      def run(dry_run: false)
        marked = @record ? @record.files.select { |_, entry| entry[:conflict] } : {}
        return NOTHING if marked.empty?

        @dry_run = dry_run
        @merged = []
        @settled = []
        @stamped = []
        @behind = []
        @warnings = []
        @trash = Trash.new(@name)
        shipped = MemoryFiles.select(@source_dir, Manifest.read(dir: @source_dir))
        marked.each { |key, entry| retry_file(key, entry, shipped) }
        settle unless dry_run
        Result.new(merged: @merged, settled: @settled, stamped: @stamped.map(&:file), behind: @behind, warnings: @warnings, trash_copy: @trash.copy_line,
                   trash_dir: @trash.dir)
      end

      private

      def retry_file(key, entry, shipped)
        return stay(key, FileStanding::NOT_SHIPPED) unless shipped.include?(key)

        incoming_sha = Merger.digest(view.paths(key)[:incoming])
        return @behind << @record.behind_entry(key, entry) if entry[:incoming_sha] && entry[:incoming_sha] != incoming_sha

        outcome = view.outcome(key)
        case outcome.status
        when :merged then merge_file(key, entry, outcome)
        when :conflict then mark(key, entry, view.behind(key, outcome, @record.version))
        when :noop, :keep then @settled << key
        when :fast_forward then mark(key, entry, behind_for(key, FileStanding::WAITS_FOR_UPGRADE))
        when :install then mark(key, entry, behind_for(key, FileStanding::FILE_MISSING))
        end
      rescue SystemCallError => e
        stay(key, FileStanding.left_as_it_is(e.message))
      end

      def behind_for(key, why) = FileStanding::Behind.new(file: key, version: @record.version, why: why)

      # Behind for now, with a reason worth no write to the record.
      def stay(key, why) = @behind << behind_for(key, why)

      # Behind, and the record says so: a write only when it has something new,
      # so a real conflict at each chi start writes nothing.
      def mark(key, entry, behind)
        @behind << behind
        @stamped << behind unless entry[:incoming_sha] && @record.behind_entry(key, entry) == behind && File.exist?(@provenance.incoming_path(key))
      end

      def merge_file(key, entry, outcome)
        return @merged << key if @dry_run
        return @merged << key if Merger.write_merged(view.paths(key)[:current], outcome, @trash)

        mark(key, entry, behind_for(key, FileStanding.no_merge(TextMerge::RACED)))
      end

      def settle
        files = @merged + @settled
        @provenance.resolve_conflicts(files.to_h { |key| [key, view.paths(key)] }) unless files.empty?
        @provenance.refresh_marks(@stamped, @source_dir) unless @stamped.empty?
        @merged.each { |key| refresh_index(key) }
      end

      # The file's size moved; its description and source stay. Not fatal, as
      # in the Installer: the file is in place. An overlay has no line.
      def refresh_index(key)
        return if ModelOverlay.bundle_overlay?(key, bundle_files: @record.files.keys, target_dir: @target_dir)

        IndexUpdater.update_index(@scope, key.delete_suffix(".md"), File.size(view.paths(key)[:current]), nil, source: @name)
      rescue StandardError => e
        @warnings << "index.md: line for #{key.delete_suffix(".md")} not updated (#{e.message})"
      end

      def view
        @view ||= Merger::Upgrade.new(provenance: @provenance, target_dir: @target_dir, source_dir: @source_dir)
      end
    end
  end
end
