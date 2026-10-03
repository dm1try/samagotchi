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
        installed.map do |name, data|
          plan_row(name, data, shipped[name], shipped_dir, chi_version)
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

      # [name, data] for each installed bundle but the system one, by name.
      def installed
        Provenance.each_installed.reject { |name, _| name == SystemBundle::BUNDLE_NAME }
      end

      def plan_row(name, data, ship, shipped_dir, chi_version)
        row = Row.new(name: name, kept: [], replaced: [])
        return skip(row, "manifest.json unreadable") if data[:error]

        row.from = data[:version].to_s
        row.scope = data[:scope].to_s.empty? ? "system" : data[:scope].to_s
        return skip(row, "not from chi") unless ship && data[:source].to_s.match?(SourceNormalizer::SHIPPED_SOURCE)

        row.to = ship.version.to_s
        return skip(row, "newer than shipped: left") if Listing.newer?(row.from, row.to)

        row.source_dir = File.join(shipped_dir, ship.source)
        return profile_row(row, data, shipped_dir, chi_version) if Profile.shipped_meta?(row.source_dir, shipped_dir: shipped_dir)
        return row.tap { |r| r.status = :up_to_date; r.to = nil } unless Listing.newer?(row.to, row.from)

        manifest = Manifest.read(dir: row.source_dir)
        if Manifest.requires_chi_failure(manifest.requires_chi, chi_version)
          return skip(row, "needs chi #{manifest.requires_chi}", keep_to: true)
        end
        return skip(row, "project scope: chi bundle upgrade #{ship.source} in the project") if row.scope == "project"
        return skip(row, "unknown scope #{row.scope}: upgrade chi or reinstall") unless MemoryPaths.scope_dir(row.scope)

        row.kept = conflicts(row, data)
        row.replaced = edited_executables(name, data)
        row.status = :would_update
        row
      end

      def profile_row(row, data, shipped_dir, chi_version)
        manifest = Manifest.read(dir: row.source_dir)
        newer = Listing.newer?(row.to, row.from)
        if newer && Manifest.requires_chi_failure(manifest.requires_chi, chi_version)
          return skip(row, "needs chi #{manifest.requires_chi}", keep_to: true)
        end

        row.adds = Profile.to_install(manifest, data).reject do |member|
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
      def conflicts(row, data)
        provenance = Provenance.new(name: row.name)
        target_dir = MemoryPaths.scope_dir!(row.scope)
        return [] unless data[:files].is_a?(Hash)

        owned = data[:files].keys.map(&:to_s)
        (Dir.glob(File.join(row.source_dir, "*.md")).map { |f| File.basename(f) }.sort & owned).select do |key|
          Merger.classify(base_path: provenance.base_path(key), current_path: File.join(target_dir, key),
                          incoming_path: File.join(row.source_dir, key)) == :conflict
        end
      end

      # Installed hooks, rules and the plugin whose sha differs from the
      # recorded one (they didn't load), as hooks/F, guardrails/F, plugin/F.
      def edited_executables(name, data)
        provenance = Provenance.new(name: name)
        edited = []
        (data[:hooks] || {}).each do |file, meta|
          edited << "hooks/#{file}" if edited?(File.join(provenance.hooks_dir, file.to_s), meta)
        end
        (data[:guardrails] || {}).each do |file, meta|
          edited << "guardrails/#{file}" if edited?(File.join(provenance.guardrails_dir, file.to_s), meta)
        end
        plugin = provenance.plugin_path(data)
        edited << "plugin/#{File.basename(plugin)}" if plugin && edited?(plugin, data[:plugin])
        edited
      end

      def edited?(path, meta)
        recorded = meta.is_a?(Hash) ? meta[:sha256] : nil
        return false if Provenance.recorded_sha(recorded).empty? || !File.file?(path)

        !Provenance.sha_matches?(path, recorded)
      end
    end
  end
end
