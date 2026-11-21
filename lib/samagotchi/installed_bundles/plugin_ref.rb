# frozen_string_literal: true

module Samagotchi
  module InstalledBundles
    # The plugin an installed bundle's record (manifest.json) names: its
    # file under plugin/, the sha256 recorded at install ("" when none
    # is; either "sha256:<hex>" or a bare hex, Sha.recorded
    # reads both), and whether its manifest called it required (a guardrail
    # plugin: plugin: required: true; an older chi ignores the key), and its
    # parts (plugin: parts:, beside the file in plugin/): name => sha256 as
    # recorded, in load order, {} without any (an older chi ignores the key).
    PluginRef = Data.define(:file, :sha256, :required, :parts) do
      def initialize(file:, sha256: "", required: false, parts: {})
        super(file: file, sha256: sha256, required: required, parts: parts.to_h { |name, sha| [name.to_s, sha.to_s] }.freeze)
      end

      # @param raw [Hash, PluginRef, nil] the record's plugin: mapping
      #   (symbol or string keys)
      # @return [PluginRef, nil] nil when there is none or it names no file
      def self.parse(raw)
        return raw if raw.is_a?(PluginRef)
        return nil unless raw.is_a?(Hash)

        h = raw.transform_keys(&:to_s)
        file = h["file"].to_s
        return nil if file.empty?

        new(file: file, sha256: h["sha256"].to_s, required: h["required"] == true, parts: h["parts"].is_a?(Hash) ? h["parts"] : {})
      end
    end
  end
end
