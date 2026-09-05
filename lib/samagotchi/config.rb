# frozen_string_literal: true

require "yaml"
require "fileutils"

module Samagotchi
  # Unified configuration registry implementing the implicit convention:
  #   ENV    SAMAGOTCHI_ATTR            (UPPER + prefix + _ = nesting)
  #   YAML   attr: / nested: {param:}   (lower snake, dot = nesting, Option A leaf keeps _)
  #   CLI    --attr / --nested-param    (kebab, _ → - for both section and leaf)
  #
  # Sections may not contain _ or - (lower alnum only). Leaves keep snake_case
  # in YAML (base_url) and kebab in CLI (base-url) via registry derivation.
  # Unknown underscore CLI (--recap_base_url) is rejected as unknown.
  #
  # Tiers (expose): :env, :config, :cli subsets. Only exposed layers are read.
  # Maps (hosts, hooks, model_aliases) are excluded — handled by ConfigFile.
  module Config
    Entry = Struct.new(:key, :yaml_path, :type, :default, :expose, :enum_values, :aliases, keyword_init: true) do
      def env_key
        "SAMAGOTCHI_" + yaml_path.map { |p| p.upcase }.join("_")
      end

      def cli_flag
        "--" + yaml_path.join("-").tr("_", "-")
      end

      def section
        yaml_path.first
      end

      def cli_exposed?
        expose.include?(:cli)
      end

      def env_exposed?
        expose.include?(:env)
      end

      def config_exposed?
        expose.include?(:config)
      end
    end

    # Section names: lower alnum only, no _ or -.
    SECTION_RE = /\A[a-z0-9]+\z/.freeze
    LEAF_RE    = /\A[a-z0-9_]+\z/.freeze

    ENTRIES = [
      # universal – env+config+cli
      Entry.new(key: "default.model",            yaml_path: %w[default model],            type: :string, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "backend",                  yaml_path: %w[backend],                   type: :enum,   default: "native",        expose: %i[env config cli], enum_values: %w[native ruby_llm]),
      Entry.new(key: "server.transport",         yaml_path: %w[server transport],          type: :enum,   default: "llama_cpp",     expose: %i[env config cli], enum_values: %w[llama_cpp mlx omlx]),
      Entry.new(key: "server.host",              yaml_path: %w[server host],               type: :string, default: "localhost",     expose: %i[env config cli], aliases: %w[LLAMA_HOST]),
      Entry.new(key: "server.port",              yaml_path: %w[server port],               type: :integer, default: 8080,            expose: %i[env config cli], aliases: %w[LLAMA_PORT]),
      Entry.new(key: "server.open_timeout",      yaml_path: %w[server open_timeout],       type: :integer, default: 10,              expose: %i[env config cli]),
      Entry.new(key: "server.read_timeout",      yaml_path: %w[server read_timeout],       type: :integer, default: 600,             expose: %i[env config cli]),

      Entry.new(key: "recap.model",              yaml_path: %w[recap model],               type: :string, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "recap.base_url",           yaml_path: %w[recap base_url],            type: :string, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "recap.host_ref",           yaml_path: %w[recap host_ref],            type: :string, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "recap.inactivity",         yaml_path: %w[recap inactivity],          type: :float,   default: nil,             expose: %i[env config cli]),
      Entry.new(key: "recap.timeout",            yaml_path: %w[recap timeout],             type: :float,   default: nil,             expose: %i[env config cli]),
      Entry.new(key: "recap.min_user_turns",     yaml_path: %w[recap min_user_turns],      type: :integer, default: nil,             expose: %i[env config cli]),

      Entry.new(key: "session.retention_days",        yaml_path: %w[session retention_days],        type: :integer, default: 14,   expose: %i[env config cli]),
      Entry.new(key: "session.max_count",             yaml_path: %w[session max_count],             type: :integer, default: 500,  expose: %i[env config cli]),
      Entry.new(key: "session.keep_status",           yaml_path: %w[session keep_status],           type: :string, default: "running", expose: %i[env config cli]),
      Entry.new(key: "session.sweep_interval_hours",  yaml_path: %w[session sweep_interval_hours],  type: :integer, default: 24,   expose: %i[env config cli]),

      Entry.new(key: "log.file",                 yaml_path: %w[log file],                 type: :string, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "log.disable",              yaml_path: %w[log disable],              type: :bool,   default: false,            expose: %i[env config cli]),

      Entry.new(key: "status.line",              yaml_path: %w[status line],              type: :string, default: "on",             expose: %i[env config cli]),
      Entry.new(key: "status.width_mode",        yaml_path: %w[status width_mode],        type: :string, default: "terminal_cap",   expose: %i[env config cli]),
      Entry.new(key: "status.max_width",         yaml_path: %w[status max_width],         type: :integer, default: 160,             expose: %i[env config cli]),
      Entry.new(key: "status.fixed_width",       yaml_path: %w[status fixed_width],       type: :integer, default: 120,             expose: %i[env config cli]),

      Entry.new(key: "context.status",           yaml_path: %w[context status],           type: :bool,   default: true,             expose: %i[env config cli]),
      Entry.new(key: "context.window_tokens",    yaml_path: %w[context window_tokens],    type: :integer, default: 256_000,         expose: %i[env config cli]),
      Entry.new(key: "context.chars_per_token",  yaml_path: %w[context chars_per_token],  type: :float,   default: 4.0,             expose: %i[env config cli]),
      Entry.new(key: "context.status_thresholds", yaml_path: %w[context status_thresholds],type: :string, default: "20,40,60,80",    expose: %i[env config cli]),
      Entry.new(key: "context.status_cadence",   yaml_path: %w[context status_cadence],   type: :integer, default: 0,               expose: %i[env config cli]),

      Entry.new(key: "thinking.ui",              yaml_path: %w[thinking ui],              type: :string, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "thinking.preview_lines",   yaml_path: %w[thinking preview_lines],   type: :integer, default: 1,               expose: %i[env config cli]),
      Entry.new(key: "thinking.render_interval", yaml_path: %w[thinking render_interval], type: :float,   default: 0.08,            expose: %i[env config cli]),

      Entry.new(key: "default.n_predict",        yaml_path: %w[default n_predict],        type: :integer, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "max_tool_output_chars",    yaml_path: %w[max_tool_output_chars],    type: :integer, default: 10_000,          expose: %i[env config cli]),

      Entry.new(key: "retry.max",                yaml_path: %w[retry max],                type: :integer, default: 5,               expose: %i[env config cli]),
      Entry.new(key: "retry.base_delay",         yaml_path: %w[retry base_delay],         type: :float,   default: 0.5,             expose: %i[env config cli]),
      Entry.new(key: "retry.max_delay",          yaml_path: %w[retry max_delay],          type: :float,   default: 8.0,             expose: %i[env config cli]),

      Entry.new(key: "read.truncate_at_bytes",        yaml_path: %w[read truncate_at_bytes],        type: :integer, default: 65_536,   expose: %i[env config cli]),
      Entry.new(key: "read.preview_bytes",            yaml_path: %w[read preview_bytes],            type: :integer, default: 12_288,   expose: %i[env config cli]),
      Entry.new(key: "read.hard_max_bytes",           yaml_path: %w[read hard_max_bytes],           type: :integer, default: 2_097_152, expose: %i[env config cli]),
      Entry.new(key: "read.telemetry_threshold_pct",  yaml_path: %w[read telemetry_threshold_pct],  type: :integer, default: 80,       expose: %i[env config cli]),

      Entry.new(key: "execute.truncate_at_bytes",       yaml_path: %w[execute truncate_at_bytes],       type: :integer, default: 65_536, expose: %i[env config cli]),
      Entry.new(key: "execute.preview_bytes",           yaml_path: %w[execute preview_bytes],           type: :integer, default: 12_288, expose: %i[env config cli]),
      Entry.new(key: "execute.telemetry_threshold_pct", yaml_path: %w[execute telemetry_threshold_pct], type: :integer, default: 80,     expose: %i[env config cli]),

      Entry.new(key: "web.port",                 yaml_path: %w[web port],                 type: :integer, default: 4567,            expose: %i[env config cli]),
      Entry.new(key: "web.host",                 yaml_path: %w[web host],                 type: :string, default: "127.0.0.1",     expose: %i[env config cli]),

      Entry.new(key: "no_interrupt",             yaml_path: %w[no_interrupt],             type: :bool,   default: false,            expose: %i[env config cli]),
      Entry.new(key: "no_default_input",         yaml_path: %w[no_default_input],         type: :bool,   default: false,            expose: %i[env config cli]),

      # env+config only
      Entry.new(key: "default.input",            yaml_path: %w[default input],            type: :string, default: nil,              expose: %i[env config]),
      Entry.new(key: "history.file",             yaml_path: %w[history file],             type: :string, default: nil,              expose: %i[env config]),
      Entry.new(key: "skip_agent_md",            yaml_path: %w[skip_agent_md],            type: :bool,   default: false,            expose: %i[env config]),
      Entry.new(key: "bridge.enable",            yaml_path: %w[bridge enable],            type: :bool,   default: false,            expose: %i[env config]),
    ].freeze

    # Fast lookup maps
    BY_KEY = ENTRIES.each_with_object({}) { |e, h| h[e.key] = e }.freeze
    BY_ENV = ENTRIES.each_with_object({}) do |e, h|
      h[e.env_key] = e
      Array(e.aliases).each { |a| h[a] = e }
    end.freeze
    BY_CLI = ENTRIES.each_with_object({}) { |e, h| h[e.cli_flag] = e if e.cli_exposed? }.freeze

    class << self
      def find_by_key(key)
        BY_KEY[key.to_s]
      end

      def find_by_env(env_key)
        BY_ENV[env_key.to_s]
      end

      def find_by_cli(flag)
        BY_CLI[flag.to_s]
      end

      def all_entries
        ENTRIES
      end

      def cli_entries
        ENTRIES.select(&:cli_exposed?)
      end

      # Coercion helpers
      def coerce(entry, raw)
        return nil if raw.nil?
        # For string, preserve as-is (including trailing spaces like "Hey Chi, ")
        if entry.type == :string
          str = raw.to_s
          return nil if str.empty? && entry.type != :string
          return str
        end
        str = raw.to_s.strip
        return nil if str.empty? && entry.type != :string

        case entry.type
        when :string
          str
        when :integer
          Integer(str, exception: false).tap do |v|
            if v.nil?
              warn "Warning: invalid integer for #{entry.key} (#{entry.env_key}): #{raw.inspect} — using default"
              return entry.default
            end
          end
        when :float
          val = Float(str, exception: false)
          if val.nil?
            warn "Warning: invalid float for #{entry.key}: #{raw.inspect}"
            return entry.default
          end
          val
        when :bool
          case str.downcase
          when "1", "true", "yes", "on" then true
          when "0", "false", "no", "off", "" then false
          else
            warn "Warning: invalid bool for #{entry.key}: #{raw.inspect} — treating as false"
            false
          end
        when :enum
          lowered = str.downcase
          allowed = entry.enum_values.map(&:downcase)
          unless allowed.include?(lowered)
            warn "Warning: invalid value for #{entry.key}: #{raw.inspect} (allowed: #{entry.enum_values.join(', ')}) — using default"
            return entry.default
          end
          # return canonical casing from enum_values
          entry.enum_values.find { |v| v.downcase == lowered }
        else
          str
        end
      end

      # Resolve value with precedence: cli > env > file > default
      # file_data: parsed YAML hash (or nil)
      # env: hash-like (ENV)
      # cli_overrides: { "key" => raw_or_coerced }
      def resolve(key, file_data: nil, env: ENV, cli_overrides: {})
        entry = find_by_key(key)
        raise ArgumentError, "unknown config key: #{key}" unless entry

        # CLI wins
        if cli_overrides.key?(entry.key)
          raw = cli_overrides[entry.key]
          # cli_overrides may already be coerced; detect by type
          return raw if already_coerced?(entry, raw)
          return coerce(entry, raw)
        end
        if cli_overrides.key?(entry.cli_flag)
          return coerce(entry, cli_overrides[entry.cli_flag])
        end

        # ENV
        if entry.env_exposed?
          env_val = nil
          env_val = env[entry.env_key] if env.key?(entry.env_key)
          # aliases (e.g., LLAMA_HOST)
          if env_val.nil? || env_val.to_s.strip.empty?
            Array(entry.aliases).each do |a|
              if env.key?(a) && !env[a].to_s.strip.empty?
                env_val = env[a]
                warn "Warning: #{a} is deprecated — use #{entry.env_key} (#{entry.key})" if a.start_with?("LLAMA_")
                break
              end
            end
          end
          unless env_val.nil? || env_val.to_s.strip.empty?
            return coerce(entry, env_val)
          end
        end

        # File
        if entry.config_exposed? && file_data.is_a?(Hash)
          file_val = lookup_yaml(file_data, entry.yaml_path)
          unless file_val.nil?
            return coerce(entry, file_val)
          end
        end

        entry.default
      end

      def already_coerced?(entry, val)
        case entry.type
        when :bool then val == true || val == false
        when :integer then val.is_a?(Integer)
        when :float then val.is_a?(Float) || val.is_a?(Integer)
        when :enum then entry.enum_values.include?(val)
        else false
        end
      end

      # Lookup yaml_path in nested hash, accepting snake leaf and kebab alias.
      # Also supports legacy flat UPPER keys (e.g., SAMAGOTCHI_DEFAULT_MODEL) for transition.
      def lookup_yaml(data, yaml_path)
        entry = ENTRIES.find { |e| e.yaml_path == yaml_path }
        # Legacy flat top-level fallback (transition): e.g., file contains SAMAGOTCHI_DEFAULT_MODEL
        if entry && data.is_a?(Hash)
          if data.key?(entry.env_key)
            return data[entry.env_key]
          end
          Array(entry.aliases).each do |a|
            return data[a] if data.key?(a)
            return data[a.to_sym] if data.key?(a.to_sym)
          end
          # Also handle legacy LLAMA_* flat keys for server.host/port
          if entry.key == "server.host" && (data.key?("LLAMA_HOST") || data.key?(:LLAMA_HOST))
            return data["LLAMA_HOST"] || data[:LLAMA_HOST]
          end
          if entry.key == "server.port" && (data.key?("LLAMA_PORT") || data.key?(:LLAMA_PORT))
            return data["LLAMA_PORT"] || data[:LLAMA_PORT]
          end
        end
        cur = data
        yaml_path.each_with_index do |seg, idx|
          return nil unless cur.is_a?(Hash)
          last = idx == yaml_path.size - 1
          if last
            # leaf: accept snake and kebab, also string/symbol keys
            if cur.key?(seg)
              return cur[seg]
            elsif cur.key?(seg.to_sym)
              return cur[seg.to_sym]
            end
            kebab = seg.tr("_", "-")
            return cur[kebab] if cur.key?(kebab)
            return cur[kebab.to_sym] if cur.key?(kebab.to_sym)
            # also case-insensitive fallback for file written with upper keys? not needed
            return nil
          else
            # section: strict lower alnum, but accept case-insensitive
            nxt = cur[seg] || cur[seg.to_sym]
            # also try kebab alias for section (should not exist per spec, but be lenient)
            nxt ||= cur[seg.tr("_", "-")] || cur[seg.tr("_", "-").to_sym]
            return nil if nxt.nil?
            cur = nxt
          end
        end
        nil
      end

      # Build a merged snapshot hash for all entries
      def snapshot(file_data: nil, env: ENV, cli_overrides: {})
        ENTRIES.each_with_object({}) do |entry, h|
          h[entry.key] = resolve(entry.key, file_data: file_data, env: env, cli_overrides: cli_overrides)
        end
      end

      # Convenience: load file_data from path + snapshot
      def load_snapshot(path: nil, env: ENV, cli_overrides: {})
        path ||= Samagotchi::ConfigFile.global_path(env: env) rescue nil
        file_data = nil
        if path && File.file?(path)
          begin
            loaded = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
            file_data = loaded if loaded.is_a?(Hash)
          rescue StandardError
            file_data = nil
          end
        end
        snapshot(file_data: file_data, env: env, cli_overrides: cli_overrides)
      end

      # In-memory store for current process (populated after CLI parse)
      def store
        @store ||= load_snapshot
      end

      def reload!(path: nil, env: ENV, cli_overrides: {})
        @cli_overrides = cli_overrides.dup
        @store = load_snapshot(path: path, env: env, cli_overrides: cli_overrides)
      end

      def cli_overrides
        @cli_overrides ||= {}
      end

      def get(key)
        entry = find_by_key(key)
        raise ArgumentError, "unknown config key: #{key}" unless entry
        # Live resolve so ENV changes (as in specs) are reflected without explicit reload
        # Use current ENV and file, plus any CLI overrides captured via reload!
        file_data = nil
        begin
          path = Samagotchi::ConfigFile.global_path rescue nil
          if path && File.file?(path)
            loaded = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
            file_data = loaded if loaded.is_a?(Hash)
          end
        rescue StandardError
          file_data = nil
        end
        resolve(entry.key, file_data: file_data, env: ENV, cli_overrides: cli_overrides)
      end

      def set_cli_overrides(overrides)
        reload!(cli_overrides: overrides)
      end

      # Validation for top-level sections
      def validate_yaml_sections(data)
        return [] unless data.is_a?(Hash)
        errors = []
        # Legacy flat UPPER keys are handled separately — don't flag them here
        legacy_keys = BY_ENV.keys
        data.each_key do |k|
          next if %w[hosts hooks model_aliases].include?(k.to_s)
          next if legacy_keys.include?(k.to_s)
          next if k.to_s == "LLAMA_HOST" || k.to_s == "LLAMA_PORT"
          # Sections are top-level keys that map to hashes (e.g., default, recap)
          # If key contains _ or -, suggest dotted form
          if k.to_s.include?("_")
            errors << "top-level key '#{k}' contains '_' — use nested form '#{k.to_s.tr('_', '.')}' (e.g., default.model)"
          end
          # Check section name shape if its value is a Hash
          if data[k].is_a?(Hash) && k.to_s.match?(/[_-]/)
            errors << "section '#{k}' must match #{SECTION_RE.inspect} (no _ or -)"
          end
        end
        errors
      end
    end
  end
end
