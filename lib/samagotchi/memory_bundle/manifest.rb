# frozen_string_literal: true

require "yaml"
require "digest"
require "fileutils"
require_relative "../context_providers"
require_relative "bundle_hook"

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
    #     skill_x.md:          # or a mapping: the description is the
    #       sha256: sha256:def456...   #   memory's index.md line
    #       description: "Use when …"
    #   plugin:                # optional — the bundle's plugin.rb (docs/plugins.md)
    #     file: plugin.rb
    #     sha256: sha256:0a1b...
    #   requires_chi: ">= 0.1.28"   # optional — a Gem::Requirement for chi's VERSION
    #   requires_chi_next: true     # optional, shipped bundles — ignored here:
    #                          #   `rake release:bump` raises requires_chi to
    #                          #   the released chi (docs/releasing.md)
    #   needs:                 # optional — outside commands the memories rely on
    #     - command: gh        #   (checked on PATH, never installed; docs/memory.md)
    #       why: reads PRs     #   optional
    #       hint: brew install gh   # optional
    #     - jq                 #   short form: just the command
    #   scripts:               # optional — files in scripts/ a context
    #     pr_context.rb: sha256:…   #   provider's command runs (installed into
    #                          #   the bundle's own dir, scripts/)
    #   context_providers:     # optional — URL → attached context source
    #     - match: '\Ahttps://…/pull/(\d+)'   # (ContextProviders)
    #       name: 'pr-\1'
    #       cmd: '{ruby} {bundle_dir}/scripts/pr_context.rb {url}'
    #       why: GitHub PR      #   optional
    #       every_seconds: 300  #   optional
    #   session_settings: [cap] # optional — the settings a session may set
    #                          #   (chi --set cost-cap.cap=3), read by the
    #                          #   plugin from ctx.settings at call time;
    #                          #   or {cap: number}: each with the type
    #                          #   --set checks (SESSION_SETTING_TYPES)
    #   includes: [a, b]       # optional — a profile (meta bundle): the
    #                          #   shipped bundles it installs; its dir holds
    #                          #   only manifest.yml (MemoryBundle::Profile)
    class Manifest
      class ValidationError < StandardError; end

      # A plugin file is a plain .rb name in the bundle's top directory.
      PLUGIN_FILE = /\A[A-Za-z0-9_][A-Za-z0-9_.-]*\.rb\z/
      # A script is a plain file name in the bundle's scripts/.
      SCRIPT_FILE = /\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/
      # A need is a plain executable name: no path, no spaces.
      NEED_COMMAND = /\A[A-Za-z0-9][A-Za-z0-9._+-]*\z/
      # A bundle name, as `chi bundle install <name>` takes a shipped one.
      BUNDLE_NAME = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/

      # files: name → "sha256:<hex>" (both forms); file_descriptions: name →
      # the description a mapping gave, for the files that have one; hooks:
      # name → BundleHook.
      attr_reader :name, :version, :scope, :description, :files, :file_descriptions, :hooks, :trust_level, :plugin, :requires_chi, :needs, :includes,
                  :scripts, :context_providers, :session_settings, :session_setting_types

      def initialize(path:)
        @path = path
        raw = load_mapping(path)
        @name     = require_str(raw, "name")
        # The name is a directory under .bundles/: never a path.
        if @name.match?(%r{[/\\\0]}) || %w[. ..].include?(@name)
          raise ValidationError, "name: #{@name.inspect} is not a bundle name (no path separators, not . or ..)"
        end

        @version  = require_str(raw, "version")
        @scope    = normalize_scope(raw["scope"])
        @description = (raw["description"] || "").to_s
        @files    = parse_files(raw["files"] || {})
        @hooks    = parse_hooks(raw["hooks"] || {})
        @file_descriptions = parse_file_descriptions(raw["files"])
        @trust_level = (raw["trust_level"] || "experimental").to_s
        @plugin = parse_plugin(raw["plugin"])
        @requires_chi = parse_requires_chi(raw["requires_chi"])
        @needs = self.class.parse_needs(raw["needs"])
        @scripts = parse_scripts(raw["scripts"])
        @context_providers = parse_context_providers(raw["context_providers"])
        @includes = parse_includes(raw["includes"])
        @session_settings = self.class.parse_session_settings(raw["session_settings"])
        @session_setting_types = self.class.parse_session_setting_types(raw["session_settings"])
      end

      # Why the install refuses this bundle's session_settings: a key whose
      # NAME.KEY is chi's own session setting (SessionConfig.clash, the
      # words chi bundle check reports too), nil when none clashes.
      # @return [String, nil]
      def session_settings_clash
        return nil if @session_settings.empty?

        require_relative "../session_config"
        SessionConfig.clash(@name, @session_settings)
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

      # Returns sha256 hex for a hook basename (e.g. "guardrails.rb"), nil
      # when it declares none (nothing to verify).
      def checksum_for_hook(basename)
        hex = @hooks[basename]&.hex
        hex unless hex.nil? || hex.empty?
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
      rescue ArgumentError => e # Gem::Requirement::BadRequirementError is one
        "its requires_chi #{requirement.inspect} is not a version requirement (#{e.message})"
      end

      # Writes a fresh manifest.yml from computed checksums at `dir`.
      # +file_descriptions+ (name → text) writes those files as mappings.
      def self.write(dir:, name:, version:, files:, scope: nil, description: "", hooks: nil, trust_level: nil,
                     plugin: nil, requires_chi: nil, needs: nil, scripts: {}, context_providers: [], file_descriptions: {},
                     session_settings: [], session_setting_types: {})
        FileUtils.mkdir_p(dir)
        manifest = {
          "name" => name,
          "version" => version,
          "description" => description
        }
        manifest["scope"] = scope if scope
        manifest["files"] = files.to_h do |key, sha| # { "file.md" => "sha256:abc..." }
          text = file_descriptions[key].to_s.strip
          [key, text.empty? ? sha : { "sha256" => sha, "description" => text }]
        end
        manifest["hooks"] = hooks.to_h { |k, v| [k.to_s, BundleHook.parse(v).to_record] } if hooks && !hooks.empty?
        manifest["trust_level"] = trust_level.to_s if trust_level && !trust_level.to_s.empty?
        if plugin
          sha = plugin[:sha256].to_s
          manifest["plugin"] = { "file" => plugin[:file].to_s, "sha256" => sha.start_with?("sha256:") ? sha : "sha256:#{sha}" }
        end
        manifest["requires_chi"] = requires_chi.to_s if requires_chi && !requires_chi.to_s.empty?
        needs = parse_needs(needs)
        manifest["needs"] = needs.map { |n| n.transform_keys(&:to_s).compact } unless needs.empty?
        manifest["scripts"] = scripts.transform_keys(&:to_s) unless scripts.empty?
        manifest["context_providers"] = context_providers.map(&:to_h) unless context_providers.empty?
        manifest["session_settings"] = session_settings_entry(session_settings, session_setting_types) unless Array(session_settings).empty?
        File.write(File.join(dir, "manifest.yml"), YAML.dump(manifest))
      end

      # A setting key a session may set (SessionConfig::KEY).
      SESSION_SETTING = /\A[A-Za-z0-9_][A-Za-z0-9_-]*\z/

      # The types a session setting may be given (session_settings: {key:
      # type}), checked by SessionConfig.check!: number (or off),
      # boolean, string; any (or a list's key) takes every scalar.
      SESSION_SETTING_TYPES = %w[number boolean string any].freeze

      # session_settings: → the keys, [] when absent: a list of plain key
      # names, or a mapping of them to types; anything else is a
      # ValidationError.
      def self.parse_session_settings(raw)
        return [] if raw.nil?

        keys = raw.is_a?(Hash) && raw.values.all?(String) ? raw.keys : raw
        keys = nil unless keys.is_a?(Array)
        unless keys&.all? { |key| (key.is_a?(String) || key.is_a?(Symbol)) && key.to_s.match?(SESSION_SETTING) }
          raise ValidationError, "session_settings: a list of setting names, or a mapping of them to types (#{raw.inspect})"
        end

        keys.map(&:to_s).uniq
      end

      # session_settings: → {key => type} for the keys a mapping types
      # (any left out), {} for a list or none.
      # @raise [ValidationError] a type that isn't one of SESSION_SETTING_TYPES
      def self.parse_session_setting_types(raw)
        return {} unless raw.is_a?(Hash)

        raw.each_with_object({}) do |(key, type), types|
          unless SESSION_SETTING_TYPES.include?(type)
            raise ValidationError, "session_settings: #{key}'s type is #{SESSION_SETTING_TYPES[0..-2].join(", ")} or " \
                                   "#{SESSION_SETTING_TYPES.last}, not #{type.inspect}"
          end
          types[key.to_s] = type unless type == "any"
        end
      end

      # session_settings: as written back: a list without types, else a
      # mapping (an untyped key as any).
      def self.session_settings_entry(keys, types)
        keys = Array(keys).map(&:to_s)
        return keys if types.nil? || types.empty?

        keys.to_h { |key| [key, types[key] || "any"] }
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

      # The manifest.yml's top-level mapping ({} for an empty file); YAML that
      # doesn't parse, or isn't a mapping, raises ValidationError, as every
      # other manifest problem does.
      def load_mapping(path)
        raw = YAML.load_file(path) || {}
        raise ValidationError, "manifest.yml is not a YAML mapping in #{File.dirname(path)}" unless raw.is_a?(Hash)

        raw
      rescue Psych::SyntaxError => e
        raise ValidationError, "manifest.yml is not valid YAML in #{File.dirname(path)}: line #{e.line}, column #{e.column}: #{e.problem}"
      rescue Psych::Exception => e
        raise ValidationError, "manifest.yml is not valid YAML in #{File.dirname(path)}: #{e.message}"
      end

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

          str = (v.is_a?(Hash) ? v["sha256"] : v).to_s
          acc[k] = if str.start_with?("sha256:")
                     str
                   else
                     "sha256:#{str}"
                   end
        end
      end

      # The descriptions of the files: entries given as a mapping.
      def parse_file_descriptions(raw)
        return {} unless raw.is_a?(Hash)

        raw.each_with_object({}) do |(k, v), acc|
          next unless k.is_a?(String) && v.is_a?(Hash)

          text = v["description"].to_s.strip
          acc[k] = text unless text.empty?
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

      # scripts: {file => sha256} → the same, "sha256:" prefixed; {} when absent.
      def parse_scripts(raw)
        return {} if raw.nil?
        raise ValidationError, "scripts: must be a mapping of file name to sha256" unless raw.is_a?(Hash)

        raw.to_h do |file, sha|
          file = file.to_s
          raise ValidationError, "scripts: #{file.inspect} isn't a plain file name in scripts/" unless file.match?(SCRIPT_FILE)

          sha = sha.to_s.strip
          [file, sha.empty? || sha.start_with?("sha256:") ? sha : "sha256:#{sha}"]
        end
      end

      # @return [Array<ContextProviders::Provider>]
      def parse_context_providers(raw)
        ContextProviders.parse_list(raw)
      rescue ContextProviders::Invalid => e
        raise ValidationError, e.message
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
        if !names.empty? && (!@files.empty? || !@hooks.empty? || @plugin || !@scripts.empty?)
          raise ValidationError, "a bundle with includes: holds only its includes (no files, hooks, plugin or scripts)"
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

          check_hook_events(k, v)
          acc[k] = BundleHook.parse(v)
        end
      end

      HOOK_EVENT_NAME = /\A[a-z][a-z0-9_]*\z/

      # A hook's events: list holds event names (one instance registered
      # for each); it and event: are one or the other.
      def check_hook_events(file, entry)
        return unless entry.key?("events")

        raw = entry["events"]
        raise ValidationError, "hooks: #{file}: give event: or events:, not both" if entry.key?("event")
        raise ValidationError, "hooks: #{file}: events: must be a list of event names" unless raw.is_a?(Array) && !raw.empty?

        raw.each do |item|
          raise ValidationError, "hooks: #{file}: events: #{item.inspect} is not an event name" unless item.is_a?(String) && item.strip.match?(HOOK_EVENT_NAME)
        end
      end
    end
  end
end
