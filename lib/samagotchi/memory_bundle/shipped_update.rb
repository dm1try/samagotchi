# frozen_string_literal: true

require "digest"
require "json"
require_relative "installer"
require_relative "listing"
require_relative "manifest"
require_relative "merger"
require_relative "provenance"
require_relative "source"
require_relative "status"
require_relative "system_bundle"
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
    module ShippedUpdate
      # status: :would_update (plan), :updated, :up_to_date, :skipped,
      # :failed. note says why for skipped/failed. kept and replaced are
      # file names; under plan they are what apply would keep or replace.
      Row = Struct.new(:name, :from, :to, :status, :note, :kept, :replaced, :source_dir, :scope, keyword_init: true)

      SHIPPED_SOURCE = %r{/lib/samagotchi/bundles/[^/]+/?\z}

      module_function

      # Read-only.
      # @return [Array<Row>] by name
      def plan(shipped_dir: SourceNormalizer::SHIPPED_DIR, chi_version: Samagotchi::VERSION)
        shipped = Listing.shipped(dir: shipped_dir).to_h { |s| [s.name, s] }
        installed_names.map do |name|
          plan_row(name, shipped[name], shipped_dir, chi_version)
        end
      end

      # The shipped bundles not installed (what the footer lists).
      # @return [Array<Listing::Shipped>]
      def not_installed(shipped_dir: SourceNormalizer::SHIPPED_DIR)
        names = installed_names
        Listing.shipped(dir: shipped_dir).reject { |s| names.include?(s.name) }
      end

      # Runs the Installer for each :would_update row; the others pass
      # through. A failing bundle doesn't stop the rest.
      # @return [Array<Row>]
      def apply(rows)
        rows.map do |row|
          next row unless row.status == :would_update

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

      def installed_names
        dir = Provenance.bundles_dir
        return [] unless File.directory?(dir)

        Dir.children(dir).reject { |e| e.start_with?(".") || e == SystemBundle::BUNDLE_NAME }
           .select { |e| File.file?(File.join(dir, e, "manifest.json")) }.sort
      end

      def plan_row(name, ship, shipped_dir, chi_version)
        row = Row.new(name: name, kept: [], replaced: [])
        data = begin
          Provenance.new(name: name).read
        rescue JSON::ParserError, SystemCallError
          nil
        end
        return skip(row, "manifest.json unreadable") unless data.is_a?(Hash)

        row.from = data[:version].to_s
        row.scope = data[:scope].to_s.empty? ? "system" : data[:scope].to_s
        return skip(row, "not from chi") unless ship && data[:source].to_s.match?(SHIPPED_SOURCE)

        row.to = ship.version.to_s
        return skip(row, "newer than shipped: left") if Listing.newer?(row.from, row.to)
        return row.tap { |r| r.status = :up_to_date; r.to = nil } unless Listing.newer?(row.to, row.from)

        row.source_dir = File.join(shipped_dir, ship.source)
        manifest = Manifest.read(dir: row.source_dir)
        if Manifest.requires_chi_failure(manifest.requires_chi, chi_version)
          return skip(row, "needs chi #{manifest.requires_chi}", keep_to: true)
        end
        return skip(row, "project scope: chi bundle upgrade #{ship.source} in the project") if row.scope == "project"

        row.kept = conflicts(row, data)
        row.replaced = edited_executables(name, data)
        row.status = :would_update
        row
      end

      def skip(row, note, keep_to: false)
        row.to = nil unless keep_to
        row.status = :skipped
        row.note = note
        row
      end

      # The .md files whose local edits conflict with the shipped version.
      def conflicts(row, data)
        provenance = Provenance.new(name: row.name)
        target_dir = Status.resolve_target_dir(row.scope)
        return [] unless data[:files]

        Dir.glob(File.join(row.source_dir, "*.md")).map { |f| File.basename(f) }.sort.select do |key|
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
        recorded = meta.is_a?(Hash) ? meta[:sha256].to_s.delete_prefix("sha256:") : ""
        return false if recorded.empty? || !File.file?(path)

        Digest::SHA256.hexdigest(File.binread(path)) != recorded
      end
    end
  end
end
