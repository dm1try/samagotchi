# frozen_string_literal: true
require "fileutils"
require "digest"
require_relative "../memory_paths"
require_relative "provenance"
require_relative "index_updater"
require_relative "merger"
require_relative "trash"
require_relative "../model_overlay"

module Samagotchi
  module MemoryBundle
    class Uninstaller
      class UninstallError < StandardError; end

      # removed_files: the bundle's own hooks/ and plugin/ files (deleted);
      # trashed_files: its memory files, moved to trash_dir (Trash), nil
      # when none was moved.
      attr_reader :warnings, :removed_files, :trashed_files

      def initialize(name:, scope: nil, force: false)
        @name = name
        @scope = scope&.to_s&.strip&.downcase
        @force = force
        @warnings = []
        @removed_files = []
        @trashed_files = []
        @trash = Trash.new(name)
      end

      def trash_dir = @trash.dir

      def run
        provenance = Provenance.new(name: @name)
        data = provenance.read
        raise UninstallError, "Bundle '#{@name}' is not installed" unless data

        # Determine scope from flag or provenance
        cli_scope = @scope.to_s.strip.empty? ? nil : @scope
        raw = cli_scope || data[:scope]&.to_s
        target_scope = (raw.nil? || raw.strip.empty?) ? "system" : raw
        target_dir = MemoryPaths.scope_dir(target_scope) or raise UninstallError, "invalid scope: #{target_scope}"

        files = data[:files] || {}
        hooks = data[:hooks] || {}
        if files.empty? && hooks.empty?
          # No file list, just remove provenance
          FileUtils.rm_rf(provenance.bundle_dir)
          return true
        end

        # A file another installed bundle lists too stays, edited or not.
        shared = files.keys.map(&:to_s).to_h do |key|
          [key, Provenance.claimants(key, scope: target_scope, except: @name)]
        end.reject { |_, others| others.empty? }

        blocked = []
        files.each do |file_key, meta|
          file_key_str = file_key.to_s
          target_path = File.join(target_dir, file_key_str)
          base_path = provenance.base_path(file_key_str)
          next unless File.exist?(target_path)
          next if shared.key?(file_key_str)
          if !@force && File.exist?(base_path) && Merger.current_modified?(base_path, target_path)
            blocked << file_key_str
            @warnings << "Skipped #{file_key_str}: local edits detected (use --force to remove)"
          end
        end

        raise UninstallError, "Uninstall blocked: #{blocked.join(', ')} has local edits (use --force)" if blocked.any?

        files.each do |file_key, _meta|
          file_key_str = file_key.to_s
          target_path = File.join(target_dir, file_key_str)
          if (others = shared[file_key_str])
            next unless File.exist?(target_path)

            @warnings << "Kept #{file_key_str}: bundle #{others.join(", ")} has it too"
            unless ModelOverlay.bundle_overlay?(file_key_str, bundle_files: files.keys.map(&:to_s), target_dir: target_dir)
              retag(target_scope, target_path, file_key_str, others.first)
            end
            next
          end
          if File.exist?(target_path)
            @trash.move(target_path)
            @trashed_files << file_key_str
          end
          # Remove index line (not fatal: a warning says so)
          begin
            IndexUpdater.remove_index(target_scope, file_key_str.delete_suffix(".md"))
            IndexUpdater.remove_index(target_scope, file_key_str) # legacy "name.md" line
          rescue StandardError => e
            @warnings << "index.md: line for #{file_key_str.delete_suffix(".md")} not removed (#{e.message})"
          end
        end

        # ── Hooks removal (bundle-owned) ──────────────────────────
        # Hooks are stored under <bundle_dir>/hooks/ and are not part of the index.
        # Explicit removal for intent; the final rm_rf sweeps it anyway.
        if hooks.is_a?(Hash) && !hooks.empty?
          hooks_dir = provenance.hooks_dir
          hooks.each do |hook_key, _meta|
            hook_key_str = hook_key.to_s
            hook_path = File.join(hooks_dir, hook_key_str)
            if File.exist?(hook_path)
              FileUtils.rm_f(hook_path)
              @removed_files << "hooks/#{hook_key_str}"
            end
          end
          # Remove hooks dir if empty, else rm_rf will clean
          FileUtils.rm_rf(hooks_dir) if Dir.exist?(hooks_dir)
        else
          # Ensure stale hooks dir removed even if provenance has no hooks map but dir exists
          FileUtils.rm_rf(provenance.hooks_dir) if Dir.exist?(provenance.hooks_dir)
        end

        plugin_path = provenance.plugin_path(data)
        @removed_files << "plugin/#{File.basename(plugin_path)}" if plugin_path && File.exist?(plugin_path)
        FileUtils.rm_rf(provenance.bundle_dir)
        true
      end

      private

      # A kept shared file's index line names the bundle that still has it
      # (a model overlay has none: the caller skips it).
      def retag(scope, path, file_key, bundle)
        IndexUpdater.update_index(scope, file_key.delete_suffix(".md"), File.size(path), source: bundle)
      rescue StandardError => e
        @warnings << "index.md: line for #{file_key.delete_suffix(".md")} not updated (#{e.message})"
      end
    end
  end
end
