# frozen_string_literal: true

require "digest"
require_relative "provenance"
require_relative "manifest"
require_relative "../version"
require_relative "index_updater"
require_relative "../memory_paths"
require_relative "../bundle_needs"
require_relative "../model_overlay"

module Samagotchi
  module MemoryBundle
    module Status
      # A scope this chi can't resolve (a newer chi's, a hand edit) isn't
      # guessed: scope_error says so, target_dir is nil and each file is
      # unchecked (no disk reads, nothing counted as missing).
      def self.bundle_status(name, scope_override: nil)
        provenance = Provenance.new(name: name)
        data = provenance.read
        return nil unless data

        raw_scope = scope_override || data[:scope]&.to_s
        scope = (raw_scope.nil? || raw_scope.strip.empty?) ? "system" : raw_scope
        target_dir = MemoryPaths.scope_dir(scope)
        files = data[:files] || {}
        details = {}
        files.each do |file_key, meta|
          file_key_str = file_key.to_s
          next details[file_key_str] = unchecked_file(meta) unless target_dir

          target_path = File.join(target_dir, file_key_str)
          base_path = provenance.base_path(file_key_str)
          stored_checksum = meta[:checksum] || meta["checksum"]
          current_checksum = File.exist?(target_path) ? Digest::SHA256.hexdigest(File.read(target_path)) : nil
          base_checksum = File.exist?(base_path) ? Digest::SHA256.hexdigest(File.read(base_path)) : nil
          modified = base_checksum && current_checksum && base_checksum != current_checksum
          missing = !File.exist?(target_path)
          # A model overlay has no index line (Installer#note_overlay).
          overlay = ModelOverlay.bundle_overlay?(file_key_str, bundle_files: files.keys.map(&:to_s), target_dir: target_dir)
          index_present = overlay ? nil : index_has_entry?(scope, file_key_str)
          details[file_key_str] = {
            conflict: meta.is_a?(Hash) && meta[:conflict] == true,
            stored_checksum: stored_checksum,
            current_checksum: current_checksum,
            base_checksum: base_checksum,
            modified: modified,
            missing: missing,
            index_present: index_present,
            overlay: overlay,
            target_path: target_path,
            base_path: base_path
          }
        end
        { provenance: data, scope: scope, scope_error: target_dir ? nil : "unknown scope: #{scope}",
          target_dir: target_dir, files: details, plugin: plugin_status(provenance, data),
          hooks_requires_failure: hooks_requires_failure(data), needs: needs_status(data) }
      end

      # Why none of the bundle's hooks load (this chi doesn't meet its
      # requires_chi, Hooks::BundleLoader), or nil: it has no hooks or meets it.
      def self.hooks_requires_failure(data)
        return nil if (data[:hooks] || {}).empty?

        Manifest.requires_chi_failure(data[:requires_chi], Samagotchi::VERSION)
      end

      # The stored needs, each with found: from this process's PATH (the
      # shell's; a worker's PATH can differ, see docs/memory.md).
      def self.needs_status(data, path: ENV["PATH"])
        Manifest.parse_needs(data[:needs]).map do |need|
          need.merge(found: BundleNeeds.found?(need[:command], path: path))
        end
      rescue Manifest::ValidationError
        []
      end

      # "needs gh (reads PRs) [ok]" / "needs gh [not found]: brew install gh"
      def self.need_line(need)
        why = need[:why] ? " (#{need[:why]})" : ""
        state = need[:found] ? "[ok]" : "[not found]"
        hint = !need[:found] && need[:hint] ? ": #{need[:hint]}" : ""
        "needs #{need[:command]}#{why} #{state}#{hint}"
      end

      # The installed plugin: {file:, path:, state:, requires_chi:,
      # requires_failure:}; state is "ok", "modified" (its sha256 differs
      # from the installed one: it won't load) or "missing". nil without one.
      def self.plugin_status(provenance, data)
        path = provenance.plugin_path(data)
        return nil unless path

        state = if !File.file?(path) then "missing"
                elsif Provenance.sha_matches?(path, data[:plugin][:sha256]) then "ok"
                else "modified"
                end
        { file: File.basename(path), path: path, state: state, requires_chi: data[:requires_chi],
          requires_failure: Manifest.requires_chi_failure(data[:requires_chi], Samagotchi::VERSION) }
      end

      def self.unchecked_file(meta)
        { conflict: meta.is_a?(Hash) && meta[:conflict] == true, stored_checksum: meta.is_a?(Hash) ? meta[:checksum] || meta["checksum"] : nil,
          unchecked: true, modified: false, missing: false, index_present: nil, overlay: false }
      end
      private_class_method :unchecked_file

      # Index lines name the entry without ".md" (Installer#update_target_index,
      # memory_write); a legacy "name.md" line counts too.
      def self.index_has_entry?(scope, file_key)
        path = IndexUpdater.index_path_for(scope)
        return false unless path && File.exist?(path)

        content = File.read(path)
        [file_key.delete_suffix(".md"), file_key].uniq.any? { |name| content.match?(IndexUpdater.managed_pattern(name)) }
      end
    end
  end
end
