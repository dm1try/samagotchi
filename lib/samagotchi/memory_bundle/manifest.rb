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
    #   plugin:                # optional — the bundle's plugin.rb (docs/plugins.md)
    #     file: plugin.rb
    #     sha256: sha256:0a1b...
    #   requires_chi: ">= 0.1.28"   # optional — a Gem::Requirement for chi's VERSION
    #   needs:                 # optional — outside commands the memories rely on
    #     - command: gh        #   (checked on PATH, never installed; docs/memory.md)
    #       why: reads PRs     #   optional
    #       hint: brew install gh   # optional
    #     - jq                 #   short form: just the command
    #   includes: [a, b]       # optional — a profile (meta bundle): the
    #                          #   shipped bundles it installs; its dir holds
    #                          #   only manifest.yml (MemoryBundle::Profile)
    class Manifest
      class ValidationError < StandardError; end

      # A plugin file is a plain .rb name in the bundle's top directory.
      PLUGIN_FILE = /\A[A-Za-z0-9_][A-Za-z0-9_.-]*\.rb\z/
      # A need is a plain executable name: no path, no spaces.
      NEED_COMMAND = /\A[A-Za-z0-9][A-Za-z0-9._+-]*\z/
      # A bundle name, as `chi bundle install <name>` takes a shipped one.
      BUNDLE_NAME = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/

      attr_reader :name, :version, :scope, :description, :files, :hooks, :trust_level, :plugin, :requires_chi, :needs, :includes

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
        @plugin = parse_plugin(raw["plugin"])
        @requires_chi = parse_requires_chi(raw["requires_chi"])
        @needs = self.class.parse_needs(raw["needs"])
        @includes = parse_includes(raw["includes"])
      end

      # A profile: it installs the bundles in includes instead of files.
      def meta?
        !@includes.empty?
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

      # @return [String, nil] the plugin's sha256 hex, "sha256:" stripped
      def checksum_for_plugin
        sha = @plugin && @plugin[:sha256].to_s
        return nil if sha.nil? || sha.empty?

        sha.delete_prefix("sha256:")
      end

      # Why chi +version+ can't load this bundle's plugin, or nil when it can
      # (or the bundle names no requirement).
      def self.requires_chi_failure(requirement, version)
        return nil if requirement.nil? || requirement.to_s.strip.empty?
        return nil if Gem::Requirement.new(*requirement.to_s.split(",").map(&:strip)).satisfied_by?(Gem::Version.new(version.to_s))

        "it requires chi #{requirement} (this is chi #{version})"
      rescue ArgumentError, Gem::Requirement::BadRequirementError => e
        "its requires_chi #{requirement.inspect} is not a version requirement (#{e.message})"
      end

      # Writes a fresh manifest.yml from computed checksums at `dir`.
      def self.write(dir:, name:, version:, scope: nil, description: "", files:, hooks: nil, trust_level: nil,
                     plugin: nil, requires_chi: nil, needs: nil)
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
        if plugin
          sha = plugin[:sha256].to_s
          manifest["plugin"] = { "file" => plugin[:file].to_s, "sha256" => sha.start_with?("sha256:") ? sha : "sha256:#{sha}" }
        end
        manifest["requires_chi"] = requires_chi.to_s if requires_chi && !requires_chi.to_s.empty?
        needs = parse_needs(needs)
        manifest["needs"] = needs.map { |n| n.transform_keys(&:to_s).compact } unless needs.empty?
        File.write(File.join(dir, "manifest.yml"), YAML.dump(manifest))
      end

      # needs: → [{command:, why:, hint:}] (why/hint a String or nil), [] when
      # absent. Takes the manifest's string-keyed YAML or the symbol-keyed
      # form provenance stores. Duplicates merge (the first one's why/hint
      # win); a list that isn't one, or a command that isn't a plain name,
      # is a ValidationError.
      def self.parse_needs(raw)
        return [] if raw.nil?
        raise ValidationError, "needs: must be a list of commands" unless raw.is_a?(Array)

        raw.each_with_object([]) do |item, acc|
          unless item.is_a?(Hash) || item.is_a?(String) || item.is_a?(Symbol)
            raise ValidationError, "needs: each item must be a command name or a mapping with command:, not #{item.inspect}"
          end

          need = item.is_a?(Hash) ? item.transform_keys(&:to_s) : { "command" => item }
          command = need["command"].to_s.strip
          raise ValidationError, "needs: #{command.inspect} is not a plain command name" unless command.match?(NEED_COMMAND)
          next if acc.any? { |n| n[:command] == command }

          acc << { command: command, why: optional_text(need["why"]), hint: optional_text(need["hint"]) }
        end
      end

      def self.optional_text(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
      private_class_method :optional_text

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

      # plugin: {file:, sha256:} → {file:, sha256:} (sha "" when not given),
      # or nil; a file that isn't a plain .rb name is a validation error.
      def parse_plugin(raw)
        return nil if raw.nil?
        raise ValidationError, "plugin: must be a mapping with file: and sha256:" unless raw.is_a?(Hash)

        file = (raw["file"] || raw[:file]).to_s.strip
        unless file.match?(PLUGIN_FILE)
          raise ValidationError, "plugin file must be a .rb file name in the bundle's top directory, not #{file.inspect}"
        end

        sha = (raw["sha256"] || raw[:sha256]).to_s.strip
        sha = "sha256:#{sha}" unless sha.empty? || sha.start_with?("sha256:")
        { file: file, sha256: sha }
      end

      # includes: → the names in order, duplicates dropped; [] when absent.
      # A meta ships nothing of its own, so files, hooks or a plugin next
      # to it is a ValidationError.
      def parse_includes(raw)
        return [] if raw.nil?
        raise ValidationError, "includes: must be a list of bundle names" unless raw.is_a?(Array)

        names = raw.map do |item|
          name = item.to_s.strip
          raise ValidationError, "includes: #{item.inspect} is not a bundle name" unless name.match?(BUNDLE_NAME)

          name
        end.uniq
        if !names.empty? && (!@files.empty? || !@hooks.empty? || @plugin)
          raise ValidationError, "a bundle with includes: holds only its includes (no files, hooks or plugin)"
        end

        names
      end

      def parse_requires_chi(raw)
        return nil if raw.nil?

        text = raw.to_s.strip
        text.empty? ? nil : text
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
