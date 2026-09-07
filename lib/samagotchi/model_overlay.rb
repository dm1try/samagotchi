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
  end
end
