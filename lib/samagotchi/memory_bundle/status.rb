# frozen_string_literal: true
require "digest"
require_relative "provenance"
require_relative "index_updater"

module Samagotchi
  module MemoryBundle
    module Status
      def self.bundle_status(name, scope_override: nil)
        provenance = Provenance.new(name: name)
        data = provenance.read
        return nil unless data

        raw_scope = scope_override || data[:scope]&.to_s
        scope = (raw_scope.nil? || raw_scope.strip.empty?) ? "system" : raw_scope
        target_dir = resolve_target_dir(scope)
        files = data[:files] || {}
        details = {}
        files.each do |file_key, meta|
          file_key_str = file_key.to_s
          target_path = File.join(target_dir, file_key_str)
          base_path = provenance.base_path(file_key_str)
          stored_checksum = meta[:checksum] || meta["checksum"]
          current_checksum = File.exist?(target_path) ? Digest::SHA256.hexdigest(File.read(target_path)) : nil
          base_checksum = File.exist?(base_path) ? Digest::SHA256.hexdigest(File.read(base_path)) : nil
          modified = base_checksum && current_checksum && base_checksum != current_checksum
          missing = !File.exist?(target_path)
          index_present = index_has_entry?(scope, file_key_str)
          details[file_key_str] = {
            stored_checksum: stored_checksum,
            current_checksum: current_checksum,
            base_checksum: base_checksum,
            modified: modified,
            missing: missing,
            index_present: index_present,
            target_path: target_path,
            base_path: base_path
          }
        end
        { provenance: data, scope: scope, target_dir: target_dir, files: details }
      end

      def self.resolve_target_dir(scope)
        case scope
        when "system"
          Samagotchi::MemoryBundle::Installer.system_dir
        when "project"
          base = Samagotchi::MemoryBundle::Installer.project_dir_base
          # If override set via Installer, use it; else compute hash
          if Samagotchi::MemoryBundle::Installer.project_dir_base_override
            base
          else
            File.join(base, "#{File.basename(Dir.pwd)}_#{Digest::MD5.hexdigest(Dir.pwd)[0..7]}")
          end
        else
          Samagotchi::MemoryBundle::Installer.system_dir
        end
      end

      def self.index_has_entry?(scope, file_key)
        path = IndexUpdater.index_path_for(scope)
        return false unless path && File.exist?(path)
        content = File.read(path)
        content.match?(IndexUpdater.managed_pattern(file_key))
      end
    end
  end
end
