# frozen_string_literal: true

require "yaml"
require "digest"
require "fileutils"

module Samagotchi
  module MemoryBundle
    # Parses and validates a bundle manifest.yml.
    #
    # Expected structure:
    #   name: my-bundle
    #   version: 1.0.0
    #   scope: system          # optional — CLI --scope wins over this
    #   description: "…"       # optional
    #   files:
    #     identity.md: sha256:abc123...
    #     commit_preferences.md: sha256:def456...
    class Manifest
      class ValidationError < StandardError; end

      attr_reader :name, :version, :scope, :description, :files

      def initialize(path:)
        @path = path
        raw = YAML.load_file(path) || {}
        @name     = require_str(raw, "name")
        @version  = require_str(raw, "version")
        @scope    = normalize_scope(raw["scope"])
        @description = (raw["description"] || "").to_s
        @files    = parse_files(raw["files"] || {})
      end

      def self.read(dir:)
        manifest_path = File.join(dir, "manifest.yml")
        raise ValidationError, "manifest.yml not found in #{dir}" unless File.exist?(manifest_path)
        new(path: manifest_path)
      end

      # Returns the expected sha256 hex digest for a given file key
      # (e.g. "identity.md"), with the "sha256:" prefix stripped.
      def checksum_for(file_key)
        raw = @files[file_key]
        return nil unless raw
        raw.start_with?("sha256:") ? raw[7..] : raw
      end

      # Writes a fresh manifest.yml from computed checksums at `dir`.
      def self.write(dir:, name:, version:, scope: nil, description: "", files:)
        FileUtils.mkdir_p(dir)
        manifest = {
          "name" => name,
          "version" => version,
          "description" => description,
        }
        manifest["scope"] = scope if scope
        manifest["files"] = files # { "file.md" => "sha256:abc..." }
        File.write(File.join(dir, "manifest.yml"), YAML.dump(manifest))
      end

      private

      def require_str(hash, key)
        val = hash[key]
        return val if val.is_a?(String) && !val.empty?
        raise ValidationError, "manifest missing required field: #{key}"
      end

      def normalize_scope(val)
        return nil if val.nil?
        v = val.to_s.strip.downcase
        %w[project system].include?(v) ? v : nil
      end

      def parse_files(raw)
        return {} unless raw.is_a?(Hash)
        raw.each_with_object({}) do |(k, v), acc|
          next unless k.is_a?(String) && !k.empty?
          str = v.to_s
          acc[k] = if str.start_with?("sha256:")
                     str
                   else
                     "sha256:#{str}"
                   end
        end
      end
    end
  end
end
