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

      attr_reader :name, :version, :scope, :description, :files, :hooks, :trust_level

      def initialize(path:)
        @path = path
        raw = YAML.load_file(path) || {}
        @name     = require_str(raw, "name")
        @version  = require_str(raw, "version")
        @scope    = normalize_scope(raw["scope"])
        @description = (raw["description"] || "").to_s
        @files    = parse_files(raw["files"] || {})
        @hooks    = parse_hooks(raw["hooks"] || {})
        @trust_level = (raw["trust_level"] || "experimental").to_s
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

      # Returns sha256 hex for a hook basename (e.g. "guardrails.rb").
      def checksum_for_hook(basename)
        raw = @hooks[basename]
        return nil unless raw
        sha = raw[:sha256] || raw["sha256"]
        return nil unless sha
        sha.to_s.start_with?("sha256:") ? sha.to_s[7..] : sha.to_s
      end

      # Writes a fresh manifest.yml from computed checksums at `dir`.
      def self.write(dir:, name:, version:, scope: nil, description: "", files:, hooks: nil, trust_level: nil)
        FileUtils.mkdir_p(dir)
        manifest = {
          "name" => name,
          "version" => version,
          "description" => description,
        }
        manifest["scope"] = scope if scope
        manifest["files"] = files # { "file.md" => "sha256:abc..." }
        if hooks && !hooks.empty?
          # Normalize hooks to string-keyed with sha256 prefix preserved
          manifest["hooks"] = hooks.transform_keys(&:to_s).transform_values do |v|
            h = v.transform_keys(&:to_s)
            h["sha256"] = h["sha256"].to_s.start_with?("sha256:") ? h["sha256"].to_s : "sha256:#{h["sha256"]}" if h["sha256"]
            h
          end
        end
        manifest["trust_level"] = trust_level.to_s if trust_level && !trust_level.to_s.empty?
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

      def parse_hooks(raw)
        return {} unless raw.is_a?(Hash)
        raw.each_with_object({}) do |(k, v), acc|
          next unless k.is_a?(String) && !k.empty?
          next unless v.is_a?(Hash)
          sha = (v["sha256"] || v[:sha256] || "").to_s
          sha = sha.start_with?("sha256:") ? sha : "sha256:#{sha}" unless sha.empty?
          event = (v["event"] || v[:event] || "").to_s.strip
          on_error = (v["on_error"] || v[:on_error] || "skip").to_s.strip
          on_error = "skip" if on_error.empty?
          priority = (v["priority"] || v[:priority] || 100).to_i
          acc[k] = {
            sha256: sha,
            event: event,
            on_error: on_error,
            priority: priority
          }
        end
      end
    end
  end
end
