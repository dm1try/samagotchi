# frozen_string_literal: true

require_relative "installer"
require_relative "listing"
require_relative "manifest"
require_relative "merger"
require_relative "profile"
require_relative "provenance"
require_relative "source"
require_relative "status"
require_relative "system_bundle"
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
    # .md files take the Installer's 3-way merge: a conflict keeps the
    # user's file (kept). Hooks, rules and the plugin are replaced; an
    # edited one (which didn't load: its sha no longer matched) is listed
    # in replaced.
    #
    # A profile (a shipped meta bundle) is updated through Profile: its row
    # is :would_update when the shipped version is newer or it has members
    # to install (Profile.to_install, less the ones this chi can't load),
    # even at the same version, so a member that failed is retried. adds
    # names them.
    module ShippedUpdate
      # status: :would_update (plan), :updated, :up_to_date, :skipped,
      # :failed. note says why for skipped/failed. kept and replaced are
      # file names; under plan they are what apply would keep or replace.
      # adds is nil but for a profile: the members it installs.
      Row = Struct.new(:name, :from, :to, :status, :note, :kept, :replaced, :source_dir, :scope, :adds, keyword_init: true)

      module_function

      # Read-only.
      # @return [Array<Row>] by name
      def plan(shipped_dir: SourceNormalizer::SHIPPED_DIR, chi_version: Samagotchi::VERSION)
        shipped = Listing.shipped(dir: shipped_dir).to_h { |s| [s.name, s] }
        installed.map do |name, bundle|
          plan_row(name, bundle, shipped[name], shipped_dir, chi_version)
        end
      end

      # The shipped bundles not installed (what the footer lists), a
      # profile's members folded into it (Listing.grouped).
      # @return [Array<Listing::Shipped>]
      def not_installed(shipped_dir: SourceNormalizer::SHIPPED_DIR)
        Listing.grouped(Listing.shipped(dir: shipped_dir), installed.map(&:first))
      end

      # Runs the Installer for each :would_update row; the others pass
      # through. A failing bundle doesn't stop the rest.
      # @return [Array<Row>]
      def apply(rows)
        rows.map do |row|
          next row unless row.status == :would_update
          next apply_profile(row) if row.adds

          installer = Installer.new(source: row.source_dir, name: row.name, scope: row.scope, strict: true, upgrade: true)
          installer.run
          row.dup.tap do |r|
            r.status = :updated
            r.kept = installer.conflicts.keys
          end
        rescue StandardError => e
          row.dup.tap do |r|
            r.status = :failed
            r.note = e.message.lines.first.to_s.strip
          end
        end
      end

      def apply_profile(row)
        result = Profile.install(row.source_dir, shipped_dir: File.dirname(row.source_dir))
        row.dup.tap do |r|
          r.adds = result.installed
          r.status = result.failed? ? :failed : :updated
          r.note = result.failed.map { |member, why| "#{member}: #{why}" }.join("; ") if result.failed?
        end
      end

      # [name, InstalledBundle] for each installed bundle but the system one, by name.
      def installed
        Provenance.each_installed.reject { |name, _| name == SystemBundle::BUNDLE_NAME }
      end

      def plan_row(name, bundle, ship, shipped_dir, chi_version)
        row = Row.new(name: name, kept: [], replaced: [])
        return skip(row, "manifest.json unreadable") if bundle.error?

        row.from = bundle.version.to_s
        row.scope = bundle.effective_scope
        return skip(row, "not from chi") unless ship && bundle.source.to_s.match?(SourceNormalizer::SHIPPED_SOURCE)

        row.to = ship.version.to_s
        return skip(row, "newer than shipped: left") if Listing.newer?(row.from, row.to)

        row.source_dir = File.join(shipped_dir, ship.source)
        return profile_row(row, bundle, shipped_dir, chi_version) if Profile.shipped_meta?(row.source_dir, shipped_dir: shipped_dir)
        return row.tap { |r| r.status = :up_to_date; r.to = nil } unless Listing.newer?(row.to, row.from)

        manifest = Manifest.read(dir: row.source_dir)
        if Manifest.requires_chi_failure(manifest.requires_chi, chi_version)
          return skip(row, "needs chi #{manifest.requires_chi}", keep_to: true)
        end
        return skip(row, "project scope: chi bundle upgrade #{ship.source} in the project") if row.scope == "project"
        return skip(row, "unknown scope #{row.scope}: upgrade chi or reinstall") unless MemoryPaths.scope_dir(row.scope)

        row.kept = conflicts(row, bundle)
        row.replaced = edited_executables(name, bundle)
        row.status = :would_update
        row
      end

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

      # The bundle's .md files whose local edits conflict with the shipped
      # version (a same-name file it didn't install is skipped, not merged).
      def conflicts(row, bundle)
        provenance = Provenance.new(name: row.name)
        target_dir = MemoryPaths.scope_dir!(row.scope)
        owned = bundle.files.keys
        (Dir.glob(File.join(row.source_dir, "*.md")).map { |f| File.basename(f) }.sort & owned).select do |key|
          Merger.classify(base_path: provenance.base_path(key), current_path: File.join(target_dir, key),
                          incoming_path: File.join(row.source_dir, key)) == :conflict
        end
      end

      # Installed hooks, rules and the plugin whose sha differs from the
      # recorded one (they didn't load), as hooks/F, guardrails/F, plugin/F.
      def edited_executables(name, bundle)
        provenance = Provenance.new(name: name)
        edited = []
        bundle.hooks.each do |file, hook|
          edited << "hooks/#{file}" if edited?(File.join(provenance.hooks_dir, file), hook.sha256)
        end
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
