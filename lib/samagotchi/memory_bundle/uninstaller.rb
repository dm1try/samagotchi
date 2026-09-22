# frozen_string_literal: true
require "fileutils"
require "digest"
require_relative "provenance"
require_relative "index_updater"
require_relative "merger"

module Samagotchi
  module MemoryBundle
    class Uninstaller
      class UninstallError < StandardError; end

      attr_reader :warnings, :removed_files

      DEFAULT_SYSTEM_DIR = File.join(Dir.home, ".config", "samagotchi", "memories")
      DEFAULT_PROJECT_DIR_BASE = File.join(Dir.home, ".config", "samagotchi", "memories", "projects")

      class << self
        attr_accessor :system_dir_override, :project_dir_base_override
        def system_dir
          system_dir_override || DEFAULT_SYSTEM_DIR
        end
        def project_dir_base
          project_dir_base_override || DEFAULT_PROJECT_DIR_BASE
        end
      end

      def initialize(name:, scope: nil, force: false)
        @name = name
        @scope = scope&.to_s&.strip&.downcase
        @force = force
        @warnings = []
        @removed_files = []
        IndexUpdater.system_dir_override = self.class.system_dir_override
        IndexUpdater.project_dir_base_override = self.class.project_dir_base_override
      end

      def run
        provenance = Provenance.new(name: @name)
        data = provenance.read
        raise UninstallError, "Bundle '#{@name}' is not installed" unless data

        # Determine scope from flag or provenance
        cli_scope = @scope.to_s.strip.empty? ? nil : @scope
        raw = cli_scope || data[:scope]&.to_s
        target_scope = (raw.nil? || raw.strip.empty?) ? "system" : raw
        target_dir = resolve_target_dir(target_scope)

        files = data[:files] || {}
        hooks = data[:hooks] || {}
        if files.empty? && hooks.empty?
          # No file list, just remove provenance
          FileUtils.rm_rf(provenance.bundle_dir)
          return true
        end

        blocked = []
        files.each do |file_key, meta|
          file_key_str = file_key.to_s
          target_path = File.join(target_dir, file_key_str)
          base_path = provenance.base_path(file_key_str)
          next unless File.exist?(target_path)
          if !@force && File.exist?(base_path) && Merger.current_modified?(base_path, target_path)
            blocked << file_key_str
            @warnings << "Skipped #{file_key_str}: local edits detected (use --force to remove)"
          end
        end

        raise UninstallError, "Uninstall blocked: #{blocked.join(', ')} has local edits (use --force)" if blocked.any?

        files.each do |file_key, _meta|
          file_key_str = file_key.to_s
          target_path = File.join(target_dir, file_key_str)
          if File.exist?(target_path)
            FileUtils.rm_f(target_path)
            @removed_files << file_key_str
          end
          # Remove index line
          begin
            IndexUpdater.remove_index(target_scope, file_key_str.delete_suffix(".md"))
            IndexUpdater.remove_index(target_scope, file_key_str) # legacy "name.md" line
          rescue => _e
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

        FileUtils.rm_rf(provenance.bundle_dir)
        true
      end

      private

      def resolve_target_dir(scope)
        case scope
        when "system", ""
          self.class.system_dir
        when "project"
          if self.class.project_dir_base_override
            self.class.project_dir_base
          else
            File.join(
              self.class.project_dir_base,
              "#{File.basename(Dir.pwd)}_#{Digest::MD5.hexdigest(Dir.pwd)[0..7]}"
            )
          end
        else
          raise UninstallError, "invalid scope: #{scope}"
        end
      end
    end
  end
end
