# frozen_string_literal: true

require_relative "asset_installer"
require_relative "installer"
require_relative "listing"
require_relative "manifest"
require_relative "manifest_standing"
require_relative "merger"
require_relative "profile"
require_relative "provenance"
require_relative "remerge"
require_relative "source"
require_relative "status"
require_relative "system_bundle"
require_relative "trash"
require_relative "../memory_paths"
require_relative "../version"

module Samagotchi
  module MemoryBundle
    # What `chi update` does to the installed bundles that chi ships: one
    # Row per installed bundle (the system bundle aside: SystemBundle.sync
    # has it). A bundle is updated when it was installed from a shipped dir
    # (its source is …/lib/samagotchi/bundles/<dir>, in a gem or a
    # checkout), chi ships it under the same name, the shipped version is
    # newer and this chi meets its requires_chi. It never installs a
    # bundle that isn't installed and never downgrades.
    #
    # .md files take the Installer's 3-way merge: a clean text merge replaces
    # the file (merged), a real conflict keeps the user's (behind). Hooks, rules,
    # the plugin and scripts are replaced; an edited one (Trash.edit?: its
    # bytes neither the recorded sha, none recorded counting as edited, nor
    # the incoming file's) is copied to the trash first and listed in
    # replaced (#trash_bound).
    #
    # A profile (a shipped meta bundle) is updated through Profile: its row
    # is :would_update when the shipped version is newer or it has members
    # to install (Profile.to_install, less the ones this chi can't load),
    # even at the same version, so a member that failed is retried. adds
    # names them.
    #
    # At the same version a row retries the files marked conflict (Remerge):
    # :would_merge when that would change anything, then :merged when a file
    # merged; what stays behind reads as behind whichever it is. Not retried for
    # a project-scope bundle: chi bundle upgrade in the project.
    module ShippedUpdate
      # status: :would_update, :would_merge (plan), :updated, :merged,
      # :up_to_date, :skipped, :failed. note says why for skipped/failed,
      # what a retry at the same version warned of, and an update's Checksum
      # mismatch warnings. merged and replaced are file
      # names, behind FileStanding::Behind; under plan they are what apply would
      # merge, replace or leave behind.
      # adds is nil but for a profile: the members it installs.
      # kept_own is nil but for a profile that installed a member: its
      # Profile.kept_own_line lines.
      # trash_copy is nil but under apply when it saved edited files
      # (Installer#trash_copy_line).
      # earlier: the merge notes on its record when the plan read it
      # (FileStanding::MergeNote): this run's own merges aren't among them.
      # manifest: what a row at the shipped version says of its manifest.yml
      # (ManifestStanding.keep's line: would keep or kept it, or why not and
      # the command), nil when nothing.
      Row = Struct.new(:name, :from, :to, :status, :note, :merged, :behind, :replaced, :source_dir, :scope, :adds, :kept_own,
                       :trash_copy, :earlier, :manifest, keyword_init: true) do
        def kept = Array(behind).map(&:file)
      end

      module_function

      # Read-only.
      # @return [Array<Row>] by name
      def plan(shipped_dir: SourceNormalizer::SHIPPED_DIR, chi_version: Samagotchi::VERSION)
        shipped = Listing.shipped(dir: shipped_dir).to_h { |s| [s.name, s] }
        installed.map do |name, bundle|
          row = plan_row(name, bundle, shipped[name], shipped_dir, chi_version)
          # A row that retried nothing still has its files that stay behind.
          row.behind = bundle.behind_files if row.status == :skipped && !bundle.error?
          row.earlier = bundle.merge_notes
          row.manifest = ManifestStanding.keep(bundle, source_dir: row.source_dir, dry_run: true).line if same_version?(row)
          row
        end
      end

      # The shipped bundles not installed (what the footer lists), a
      # profile's members folded into it (Listing.grouped).
      # @return [Array<Listing::Shipped>]
      def not_installed(shipped_dir: SourceNormalizer::SHIPPED_DIR)
        Listing.grouped(Listing.shipped(dir: shipped_dir), installed.map(&:first))
      end

      # The installed bundles chi doesn't update (plan's "not from chi"), for
      # chi update's re-check: not a profile (no code of its own, its members
      # are chi's), nor one whose record doesn't read (its row says so).
      # @return [Array<InstalledBundle>]
      def external(shipped_dir: SourceNormalizer::SHIPPED_DIR)
        shipped = Listing.shipped(dir: shipped_dir).to_h { |s| [s.name, s] }
        installed.filter_map { |name, bundle| bundle unless bundle.error? || bundle.profile? || from_chi?(bundle, shipped[name]) }
      end

      # Runs the Installer for each :would_update row, Remerge for each
      # :would_merge row; the others pass through. A failing bundle doesn't
      # stop the rest. A bundle at the shipped version whose record an older
      # chi wrote keeps the shipped manifest.yml (#keep_manifest).
      # @return [Array<Row>]
      def apply(rows)
        rows.map { |row| keep_manifest(apply_row(row)) }
      end

      def apply_row(row)
        return apply_remerge(row) if row.status == :would_merge
        return row unless row.status == :would_update
        return apply_profile(row) if row.adds

        installer = Installer.new(source: row.source_dir, name: row.name, scope: row.scope, strict: true, upgrade: true,
                                  shipped_dir: File.dirname(row.source_dir))
        installer.run
        row.dup.tap do |r|
          r.status = :updated
          r.merged = installer.merged_files
          r.behind = installer.behind
          r.trash_copy = installer.trash_copy_line
          # The integrity check's warnings; the rest of the Installer's say
          # what the row's merged and behind already do.
          mismatches = installer.warnings.grep(/\AChecksum mismatch/)
          r.note = mismatches.join("; ") unless mismatches.empty?
        end
      rescue StandardError => e
        row.dup.tap do |r|
          r.status = :failed
          r.note = e.message.lines.first.to_s.strip
          r.merged = installer&.merged_files || []
          r.behind = installer&.behind || []
          r.trash_copy = installer&.trash_copy_line
        end
      end

      # The statuses of a row at the shipped version, in the plan and after
      # apply: its record can keep the shipped dir's manifest.yml.
      SAME_VERSION = %i[up_to_date would_merge merged].freeze

      def same_version?(row) = !row.source_dir.nil? && SAME_VERSION.include?(row.status)

      # ManifestStanding.keep from the shipped dir for a same-version row: a
      # record an older chi wrote keeps the shipped manifest.yml, and the row
      # says so (or why not). A bumped bundle gets the file from its Installer.
      # @return [Row] the row
      def keep_manifest(row)
        return row unless same_version?(row)

        bundle = Provenance.new(name: row.name).record
        row.manifest = bundle && ManifestStanding.keep(bundle, source_dir: row.source_dir).line
        row
      rescue JSON::ParserError, SystemCallError
        row
      end

      def apply_remerge(row)
        done = remerge(row).run
        row.dup.tap do |r|
          r.status = done.merged.empty? ? :up_to_date : :merged
          r.merged = done.merged
          r.behind = done.behind
          r.trash_copy = done.trash_copy
          r.note = note_of(done)
        end
      end

      def apply_profile(row)
        result = Profile.install(row.source_dir, shipped_dir: File.dirname(row.source_dir))
        row.dup.tap do |r|
          r.adds = result.installed
          r.kept_own = result.kept_own_lines
          r.status = result.failed? ? :failed : :updated
          r.note = result.failed.map { |member, why| "#{member}: #{why}" }.join("; ") if result.failed?
        end
      end

      # [name, InstalledBundle] for each installed bundle but the system one, by name.
      def installed
        Provenance.each_installed.reject { |name, _| name == SystemBundle::BUNDLE_NAME }
      end

      # Whether it is the bundle chi ships as +ship+ (nil: none of its name).
      def from_chi?(bundle, ship) = !ship.nil? && bundle.source.to_s.match?(SourceNormalizer::SHIPPED_SOURCE)

      def plan_row(name, bundle, ship, shipped_dir, chi_version)
        row = Row.new(name: name, merged: [], behind: [], replaced: [])
        return skip(row, "manifest.json unreadable") if bundle.error?

        row.from = bundle.version.to_s
        row.scope = bundle.effective_scope
        return skip(row, "not from chi") unless from_chi?(bundle, ship)

        row.to = ship.version.to_s
        return skip(row, "newer than shipped: left") if Listing.newer?(row.from, row.to)

        row.source_dir = File.join(shipped_dir, ship.source)
        return profile_row(row, bundle, shipped_dir, chi_version) if Profile.shipped_meta?(row.source_dir, shipped_dir: shipped_dir)
        return same_version_row(row, bundle) unless Listing.newer?(row.to, row.from)

        manifest = Manifest.read(dir: row.source_dir)
        if Manifest.requires_chi_failure(manifest.requires_chi, chi_version)
          return skip(row, "needs chi #{manifest.requires_chi}", keep_to: true)
        end
        return skip(row, "project scope: chi bundle upgrade #{ship.source} in the project") if row.scope == "project"
        return skip(row, "unknown scope #{row.scope}: upgrade chi or reinstall") unless MemoryPaths.scope_dir(row.scope)

        forecast = forecast(row, bundle)
        row.merged = forecast.merged
        row.behind = forecast.behind
        row.replaced = trash_bound(name, bundle, manifest, row.source_dir)
        row.status = :would_update
        row
      rescue SystemCallError => e
        # A file it can't read: the upgrade would fail on it, so this is that
        # row, not a crash of the whole plan. Apply passes it through.
        row.status = :failed
        row.note = Trash.failure_message(e)
        row
      end

      # Up to date, unless a file marked conflict could settle now or stays behind.
      def same_version_row(row, bundle)
        row.to = nil
        row.status = :up_to_date
        if row.scope == "project" || !MemoryPaths.scope_dir(row.scope)
          row.behind = bundle.behind_files
          return row
        end

        planned = remerge(row).run(dry_run: true)
        row.merged = planned.merged
        row.behind = planned.behind
        row.note = note_of(planned)
        row.status = :would_merge if planned.work?
        row
      end

      def remerge(row)
        Remerge.new(name: row.name, scope: row.scope, target_dir: MemoryPaths.scope_dir!(row.scope), source_dir: row.source_dir)
      end

      def note_of(remerged) = remerged.warnings.empty? ? nil : remerged.warnings.join("; ")

      def profile_row(row, bundle, shipped_dir, chi_version)
        manifest = Manifest.read(dir: row.source_dir)
        newer = Listing.newer?(row.to, row.from)
        if newer && Manifest.requires_chi_failure(manifest.requires_chi, chi_version)
          return skip(row, "needs chi #{manifest.requires_chi}", keep_to: true)
        end

        row.adds = Profile.to_install(manifest, bundle).reject do |member|
          Manifest.requires_chi_failure(Manifest.read(dir: File.join(shipped_dir, member)).requires_chi, chi_version)
        rescue Manifest::ValidationError, Psych::Exception
          false # apply reports it failing
        end
        row.to = nil unless newer
        row.status = newer || row.adds.any? ? :would_update : :up_to_date
        row
      end

      def skip(row, note, keep_to: false)
        row.to = nil unless keep_to
        row.status = :skipped
        row.note = note
        row
      end

      # What the upgrade would do to the bundle's .md files that local edits and
      # the shipped version both changed (a same-name file it didn't install is
      # skipped, not merged). Every shipped *.md, not MemoryFiles.select: see
      # Merger::Upgrade#forecast.
      def forecast(row, bundle)
        shipped = Dir.glob(File.join(row.source_dir, "*.md")).map { |f| File.basename(f) }.sort
        Merger::Upgrade.new(provenance: Provenance.new(name: row.name), target_dir: MemoryPaths.scope_dir!(row.scope),
                            source_dir: row.source_dir).forecast(shipped & bundle.files.keys, version: row.to)
      end

      # What the upgrade from +source_dir+ copies to the trash, as
      # hooks/F, guardrails/F, plugin/F, scripts/F: Trash.edit? over the files
      # AssetInstaller replaces or removes, each against the file it puts in
      # its place. Hooks: the ones install_hooks copies (listed, else every
      # hooks/*.rb; present, not links) and the ones prune_dropped_hooks
      # removes (recorded, no longer shipped; no incoming). Rules, the plugin
      # and scripts: their whole folder, which the upgrade replaces.
      def trash_bound(name, bundle, manifest, source_dir)
        provenance = Provenance.new(name: name)
        rules = Dir.glob(File.join(source_dir, "guardrails", "*.yml")).sort
                   .reject { |file| AssetInstaller.linked?(file, source_dir) }
        plugin = manifest.plugin ? { manifest.plugin[:file] => File.join(source_dir, manifest.plugin[:file]) } : {}
        scripts = manifest.scripts.keys.to_h { |file| [file, File.join(source_dir, "scripts", file)] }
        trash_bound_hooks(provenance, bundle, manifest, source_dir) +
          Trash.edits(provenance.guardrails_dir, "guardrails", bundle.guardrails, rules.to_h { |file| [File.basename(file), file] }) +
          Trash.edits(provenance.plugin_dir, "plugin", bundle.plugin_shas, plugin) +
          Trash.edits(provenance.scripts_dir, "scripts", bundle.scripts, scripts)
      end

      # #trash_bound's hooks: AssetInstaller#install_hooks' set (incoming: the
      # source's file), then #prune_dropped_hooks' (incoming: none). A stray
      # file in hooks/ is in neither: the upgrade leaves it.
      def trash_bound_hooks(provenance, bundle, manifest, source_dir)
        src = ->(file) { File.join(source_dir, "hooks", file) }
        listed = manifest.hooks.keys.select { |file| file.is_a?(String) && !file.empty? }
        listed = Dir.glob(src.call("*.rb")).map { |file| File.basename(file) } if manifest.hooks.empty?
        shipped = listed.reject do |file|
          (File.symlink?(src.call(file)) || File.exist?(src.call(file))) && AssetInstaller.linked?(src.call(file), source_dir)
        end
        incoming = shipped.select { |file| File.exist?(src.call(file)) }.to_h { |file| [file, src.call(file)] }
        incoming.merge!((bundle.hooks.keys - shipped).to_h { |file| [file, nil] })
        incoming.filter_map do |file, from|
          "hooks/#{file}" if Trash.edit?(File.join(provenance.hooks_dir, file), recorded: bundle.hooks[file]&.sha256, incoming: from)
        end
      end

      # Installed rules and the plugin whose sha differs from the recorded
      # one (they didn't load), as guardrails/F, plugin/F.
      def edited_executables(name, bundle)
        provenance = Provenance.new(name: name)
        edited = []
        bundle.guardrails.each do |file, sha|
          edited << "guardrails/#{file}" if edited?(File.join(provenance.guardrails_dir, file), sha)
        end
        plugin = provenance.plugin_path(bundle)
        edited << "plugin/#{File.basename(plugin)}" if plugin && edited?(plugin, bundle.plugin.sha256)
        edited
      end

      # Whether the file differs from its recorded sha (none recorded: no).
      def edited?(path, recorded)
        return false if Provenance.recorded_sha(recorded).empty? || !File.file?(path)

        !Provenance.sha_matches?(path, recorded)
      end
    end
  end
end
