# frozen_string_literal: true

module Samagotchi
  module MemoryBundle
    # The plugin an installed bundle's record (manifest.json) names: its
    # file under plugin/, the sha256 recorded at install ("" when none
    # is; either "sha256:<hex>" or a bare hex, Provenance.recorded_sha
    # reads both), and whether its manifest called it required (a guardrail
    # plugin: plugin: required: true; an older chi ignores the key).
    PluginRef = Data.define(:file, :sha256, :required) do
      def initialize(file:, sha256: "", required: false)
        super
      end

      # @param raw [Hash, PluginRef, nil] the record's plugin: mapping
      #   (symbol or string keys)
      # @return [PluginRef, nil] nil when there is none or it names no file
      def self.parse(raw)
        return raw if raw.is_a?(PluginRef)
        return nil unless raw.is_a?(Hash)

        h = raw.transform_keys(&:to_s)
        file = h["file"].to_s
        file.empty? ? nil : new(file: file, sha256: h["sha256"].to_s, required: h["required"] == true)
      end
    end
  end
end
