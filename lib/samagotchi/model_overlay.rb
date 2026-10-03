# frozen_string_literal: true

require_relative "tools/memory"

module Samagotchi
  # Model-specific memory overlays.
  #
  # A memory entry `<name>` may have a companion file `<name>.<modelkey>.md` in
  # the same scope directory. When the entry is read under a matching model, the
  # overlay body is appended automatically.
  #
  # Key invariants:
  # - The base entry is the contract. An overlay only adds model-specific guidance
  #   and never contradicts the base protocol.
  # - One key function is shared by both read and write paths.
  # - Overlays are resolved only implicitly (via a read of the base); they are
  #   not first-class memories.
  class ModelOverlay
    # Derive the lowercase-dashed key from a bare model name.
    #
    # Transform: downcase → replace every non-alphanumeric run with `-` →
    # squeeze consecutive `-` → trim leading/trailing `-`.
    #
    # Examples:
    #   "qwen3.6-35b-a3b" => "qwen3-6-35b-a3b"
    #   "gemma4o"         => "gemma4o"
    #   nil / ""          => nil
    #
    # This is THE key function — used by BOTH read and write paths.
    def self.key_for(model_name)
      return nil if model_name.nil? || model_name.to_s.strip.empty?

      key = model_name.to_s
        .downcase
        .gsub(/[^a-z0-9]+/, "-")
        .gsub(/-+/, "-")
        .sub(/\A-/, "")
        .sub(/-\z/, "")
      key.empty? ? nil : key
    end

    # Return the expected file path for an overlay in the given scope.
    # Respects MemoryBundle overrides (delegates to Tools::MemoryRead.memories_dir).
    def self.overlay_path_for(name, key, scope)
      return nil unless key && !key.to_s.strip.empty?
      File.join(Tools::MemoryRead.memories_dir(scope), "#{name}.#{key.to_s.strip}.md")
    end

    # Regex matching overlay file names: /<something>.<lowercase-dashed-key>.md\z
    # Useful for tooling, tests, and future index suppression.
    OVERLAY_SUFFIX_PATTERN = /\.([a-z0-9\-]+)\.md\z/

    # The base file name (`tips.md`) an overlay-looking name
    # (`tips.qwen3.md`) would belong to, or nil when it doesn't match the
    # suffix pattern.
    def self.base_file_for(path)
      match = File.basename(path.to_s).match(OVERLAY_SUFFIX_PATTERN)
      return nil unless match

      stem = File.basename(path.to_s).delete_suffix(match[0])
      stem.empty? ? nil : "#{stem}.md"
    end

    # Whether +path+ is a model overlay: its name matches the suffix pattern
    # and its base `<stem>.md` exists in one of +base_dirs+ (default: the
    # file's own dir) or is one of +base_names+. A memory whose name has a
    # dot and a sibling of the same stem reads as an overlay too (a
    # leftover ambiguity).
    def self.overlay_file?(path, base_dirs: [File.dirname(path.to_s)], base_names: [])
      base = base_file_for(path)
      return false unless base

      base_names.map { |n| File.basename(n.to_s) }.include?(base) ||
        base_dirs.compact.any? { |dir| File.file?(File.join(dir, base)) }
    end

    # How a bundle's installer, status and uninstaller tell an overlay
    # (they agree, so a line the installer left out isn't "no-index"): the
    # base is one of +bundle_files+ (basenames), or it is nowhere in
    # +target_dir+ (an orphan overlay; it loads once the base exists). A
    # base only in +target_dir+ (the user's own memory) doesn't count.
    def self.bundle_overlay?(file_key, bundle_files:, target_dir:)
      base = base_file_for(file_key)
      return false unless base

      overlay_file?(file_key, base_dirs: [], base_names: bundle_files) ||
        !File.file?(File.join(target_dir, base))
    end
  end
end
