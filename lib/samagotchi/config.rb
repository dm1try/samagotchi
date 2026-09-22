# frozen_string_literal: true

require "yaml"
require "json"
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
  # Maps (hosts, hooks, model_aliases) are excluded from the registry — they are
  # handled by ConfigFile (same file, below), which reads the *same* parsed YAML
  # through ConfigFile.read_yaml so the file is parsed once per change.
  module Config
    Entry = Struct.new(:key, :yaml_path, :type, :default, :expose, :enum_values, :aliases, :yaml_aliases, keyword_init: true) do
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
      Entry.new(key: "server.host",              yaml_path: %w[server host],               type: :string, default: "localhost",     expose: %i[env config cli]),
      Entry.new(key: "server.port",              yaml_path: %w[server port],               type: :integer, default: 8080,            expose: %i[env config cli]),
      Entry.new(key: "server.open_timeout",      yaml_path: %w[server open_timeout],       type: :integer, default: 10,              expose: %i[env config cli]),
      Entry.new(key: "server.read_timeout",      yaml_path: %w[server read_timeout],       type: :integer, default: 600,            expose: %i[env config cli]),

      Entry.new(key: "recap.enabled",            yaml_path: %w[recap enabled],             type: :bool,   default: nil,              expose: %i[env config]),
      Entry.new(key: "recap.model",              yaml_path: %w[recap model],               type: :string, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "recap.base_url",           yaml_path: %w[recap base_url],            type: :string, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "recap.host_ref",           yaml_path: %w[recap host_ref],            type: :string, default: nil,              expose: %i[env config cli], yaml_aliases: %w[host]),
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
      Entry.new(key: "context.window_tokens",    yaml_path: %w[context window_tokens],    type: :integer, default: nil,             expose: %i[env config cli]),
      Entry.new(key: "context.chars_per_token",  yaml_path: %w[context chars_per_token],  type: :float,   default: 4.0,             expose: %i[env config cli]),
      Entry.new(key: "context.status_thresholds", yaml_path: %w[context status_thresholds],type: :string, default: "20,40,60,80",    expose: %i[env config cli]),
      Entry.new(key: "context.status_cadence",   yaml_path: %w[context status_cadence],   type: :integer, default: 0,               expose: %i[env config cli]),

      Entry.new(key: "thinking.ui",              yaml_path: %w[thinking ui],              type: :string, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "thinking.preview_lines",   yaml_path: %w[thinking preview_lines],   type: :integer, default: 1,               expose: %i[env config cli]),
      Entry.new(key: "thinking.render_interval", yaml_path: %w[thinking render_interval], type: :float,   default: 0.08,            expose: %i[env config cli]),
      Entry.new(key: "thinking.turn_preamble",   yaml_path: %w[thinking turn_preamble],   type: :bool,   default: true,             expose: %i[env config cli]),

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
      Entry.new(key: "web.markdown",             yaml_path: %w[web markdown],             type: :bool,    default: false,           expose: %i[env config cli]),

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
        resolve_with_origin(key, file_data: file_data, env: env, cli_overrides: cli_overrides).first
      end

      # Same as #resolve, plus the layer the value came from:
      # :cli, :env, :file or :default.
      def resolve_with_origin(key, file_data: nil, env: ENV, cli_overrides: {})
        entry = find_by_key(key)
        raise ArgumentError, "unknown config key: #{key}" unless entry

        # CLI wins
        if cli_overrides.key?(entry.key)
          raw = cli_overrides[entry.key]
          # cli_overrides may already be coerced; detect by type
          return [raw, :cli] if already_coerced?(entry, raw)
          return [coerce(entry, raw), :cli]
        end
        if cli_overrides.key?(entry.cli_flag)
          return [coerce(entry, cli_overrides[entry.cli_flag]), :cli]
        end

        # ENV
        if entry.env_exposed?
          env_val = env[entry.env_key] if env.key?(entry.env_key)
          unless env_val.nil? || env_val.to_s.strip.empty?
            return [coerce(entry, env_val), :env]
          end
        end

        # File
        if entry.config_exposed? && file_data.is_a?(Hash)
          file_val = lookup_yaml(file_data, entry.yaml_path)
          unless file_val.nil?
            return [coerce(entry, file_val), :file]
          end
        end

        [entry.default, :default]
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

      # Lookup yaml_path in nested hash, accepting snake leaf, kebab alias,
      # entry-specific yaml_aliases, and legacy flat UPPER keys (e.g.,
      # SAMAGOTCHI_DEFAULT_MODEL) for transition.
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
        end
        cur = data
        yaml_path.each_with_index do |seg, idx|
          return nil unless cur.is_a?(Hash)
          last = idx == yaml_path.size - 1
          if last
            candidates = [seg, seg.to_sym]
            kebab = seg.tr("_", "-")
            candidates.push(kebab, kebab.to_sym)
            Array(entry && entry.yaml_aliases).each do |alias_leaf|
              candidates.push(alias_leaf, alias_leaf.to_sym)
            end
            candidates.each do |candidate|
              return cur[candidate] if cur.key?(candidate)
            end
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
        file_data = Samagotchi::ConfigFile.read_yaml(env: env, path: path) if path
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
        get_with_origin(key).first
      end

      # [value, origin] for the live value #get returns; origin is one of
      # :cli, :env, :file, :default.
      def get_with_origin(key)
        entry = find_by_key(key)
        raise ArgumentError, "unknown config key: #{key}" unless entry
        # Live resolve so ENV changes (as in specs) are reflected without explicit reload
        # Use current ENV and file (via ConfigFile's cached reader), plus any CLI
        # overrides captured via reload!
        path = Samagotchi::ConfigFile.global_path rescue nil
        file_data = Samagotchi::ConfigFile.read_yaml(path: path) if path
        resolve_with_origin(entry.key, file_data: file_data, env: ENV, cli_overrides: cli_overrides)
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

  # Global config-file access: the single YAML reader (cached per
  # path+mtime+size), plus the map-shaped helpers the registry excludes
  # (hosts, model_aliases) and the recap section resolution. All of it
  # shares Config's precedence (CLI > ENV > file > default) for scalars.
  module ConfigFile
    XDG_CONFIG_HOME_ENV = "XDG_CONFIG_HOME"
    CONFIG_DIR = "samagotchi"
    CONFIG_FILE = "config.yml"
    DEFAULT_MODEL_KEY = "SAMAGOTCHI_DEFAULT_MODEL"
    MODEL_ALIASES_KEY = "model_aliases"

    module_function

    # Single YAML reader for the global config file. Memoised per
    # (path, mtime, size) so repeated Config.get / map-helper calls within a
    # process parse the file at most once per on-disk change. Returns the
    # parsed Hash or nil (missing file / parse error / non-mapping top level).
    def read_yaml(env: ENV, path: global_path(env: env))
      return nil if path.nil?
      cache = @yaml_cache ||= {}
      unless File.file?(path)
        cache.delete(path)
        return nil
      end
      stat = File.stat(path)
      key = [stat.mtime.to_r, stat.size]
      hit = cache[path]
      return hit[1] if hit && hit[0] == key

      data = begin
        YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      rescue StandardError
        nil
      end
      data = nil unless data.is_a?(Hash)
      cache[path] = [key, data]
      data
    end

    # Invalidate the parsed-YAML cache (called after writers modify the file).
    def clear_yaml_cache!(path = nil)
      cache = @yaml_cache
      return if cache.nil?
      if path
        cache.delete(path)
      else
        cache.clear
      end
    end

    # New unified loader: delegates to Samagotchi::Config registry.
    # Breaking: YAML now expects lower snake dotted paths (default.model)
    # instead of UPPER scalar keys. For compatibility, UPPER keys are warned
    # and ignored — env wins over file as before, now via registry precedence
    # (CLI > ENV > file > default). Returns true if file existed.
    def load_global_env!(env: ENV, path: global_path(env: env))
      existed = File.file?(path)
      raw = read_yaml(env: env, path: path) || {}
      if existed
        Samagotchi::Config.validate_yaml_sections(raw).each { |w| warn "Warning: #{w}" }
        # Warn on legacy UPPER keys
        raw.each_key do |k|
          if k.to_s.match?(/\A[A-Z_]{2,}\z/) && k.to_s.start_with?("SAMAGOTCHI_")
            warn "Warning: config key '#{k}' is legacy UPPER — use '#{k.to_s.downcase.sub(/^samagotchi_/, '').tr('_', '.')}' (e.g., default.model)"
          end
        end
      end
      # For process-wide access, prime the Config store (so Config.get works)
      Samagotchi::Config.reload!(path: path, env: env, cli_overrides: {})
      # Keep ENV in sync for any code still reading ENV directly (transition).
      # Only for keys that were actually present in file (not defaults) to
      # avoid polluting ENV with defaults.
      Samagotchi::Config.all_entries.each do |entry|
        next unless entry.env_exposed?
        # check if file actually contained this key (including legacy flat)
        file_val = Samagotchi::Config.lookup_yaml(raw, entry.yaml_path)
        file_val ||= raw[entry.env_key] if raw.key?(entry.env_key)
        Array(entry.aliases).each { |a| file_val ||= raw[a] if raw.key?(a) }
        next if file_val.nil?
        val = Samagotchi::Config.store[entry.key]
        next if val.nil?
        env[entry.env_key] = val.to_s unless env.key?(entry.env_key)
      end
      existed
    end

    def config_dir(env: ENV)
      config_home = env.fetch(XDG_CONFIG_HOME_ENV, "").to_s.strip
      base_dir = config_home.empty? ? File.expand_path("~/.config") : config_home
      File.join(base_dir, CONFIG_DIR)
    end

    def global_path(env: ENV)
      File.join(config_dir(env: env), CONFIG_FILE)
    end

    HOSTS_KEY = "hosts"
    VALID_TRANSPORTS_FOR_CONFIG = %w[llama_cpp mlx omlx].freeze
    HOST_NAME_RE = /\A[a-z0-9][a-z0-9._-]*\z/i

    def hosts_config(env: ENV, path: global_path(env: env))
      data = read_yaml(env: env, path: path)
      raw_hosts = data[HOSTS_KEY] if data.is_a?(Hash)

      # ENV override: SAMAGOTCHI_HOSTS_JSON (used to propagate to workers)
      env_json = env["SAMAGOTCHI_HOSTS_JSON"].to_s.strip
      unless env_json.empty?
        begin
          parsed_env = JSON.parse(env_json)
          raw_hosts = parsed_env if parsed_env.is_a?(Hash)
        rescue StandardError
          nil
        end
      end

      normalized = {}
      if raw_hosts.is_a?(Hash)
        raw_hosts.each do |raw_name, raw_cfg|
          name = raw_name.to_s.strip
          next if name.empty?
          unless name.match?(HOST_NAME_RE)
            warn "Warning: ignoring hosts entry '#{name}': must match /[a-z0-9][a-z0-9._-]*/i"
            next
          end
          lowered = name.downcase
          unless raw_cfg.is_a?(Hash)
            warn "Warning: ignoring hosts entry '#{name}': expected mapping"
            next
          end
          host = raw_cfg["host"] || raw_cfg[:host]
          port = raw_cfg["port"] || raw_cfg[:port]
          transport = raw_cfg["transport"] || raw_cfg[:transport]
          enabled = raw_cfg.key?("enabled") ? raw_cfg["enabled"] : (raw_cfg.key?(:enabled) ? raw_cfg[:enabled] : true)
          if enabled == false || enabled.to_s.strip.downcase == "false"
            next
          end
          host = host.to_s.strip
          if host.empty?
            warn "Warning: ignoring hosts entry '#{name}': host is required"
            next
          end
          port_val = port.to_s.strip.empty? ? 8080 : port.to_i
          if port_val <= 0 || port_val > 65535
            warn "Warning: ignoring hosts entry '#{name}': invalid port"
            next
          end
          transport_val = transport.to_s.strip.downcase
          if transport_val.empty?
            transport_val = nil
          elsif !VALID_TRANSPORTS_FOR_CONFIG.include?(transport_val)
            warn "Warning: ignoring hosts entry '#{name}': unknown transport '#{transport_val}'"
            next
          end
          normalized[lowered] = { name: lowered, host: host, port: port_val, transport: transport_val ? transport_val.to_sym : nil, original_name: name }
        end
      end

      # If no hosts defined, synthesize "default" from SAMAGOTCHI_SERVER_HOST/PORT
      if normalized.empty?
        default_host = env.fetch("SAMAGOTCHI_SERVER_HOST", "localhost").to_s.strip
        default_host = "localhost" if default_host.empty?
        default_port = env.fetch("SAMAGOTCHI_SERVER_PORT", "8080").to_s.strip
        default_port = default_port.empty? ? 8080 : default_port.to_i
        default_port = 8080 if default_port <= 0 || default_port > 65535
        transport_env = env.fetch("SAMAGOTCHI_SERVER_TRANSPORT", "").to_s.strip.downcase
        transport_sym = VALID_TRANSPORTS_FOR_CONFIG.include?(transport_env) ? transport_env.to_sym : nil
        normalized["default"] = { name: "default", host: default_host, port: default_port, transport: transport_sym, original_name: "default" }
      end
      normalized
    rescue StandardError
      {}
    end

    # Resolve the `recap:` section through the Config registry so scalar
    # recap settings share the single precedence path (CLI > ENV > file >
    # default). Returns false when explicitly disabled (file `recap: false`
    # or `recap: {enabled: false}` / SAMAGOTCHI_RECAP_ENABLED=false), nil when
    # nothing recap-related is configured, otherwise a Hash of the present
    # values (nil entries for absent ones).
    def recap_config(env: ENV, path: global_path(env: env))
      data = read_yaml(env: env, path: path) || {}
      section = data["recap"]
      return false if section == false

      opts = { file_data: data, env: env, cli_overrides: Samagotchi::Config.cli_overrides }
      return false if Samagotchi::Config.resolve("recap.enabled", **opts) == false

      base_url = nonempty_str(Samagotchi::Config.resolve("recap.base_url", **opts))
      host_ref = nonempty_str(Samagotchi::Config.resolve("recap.host_ref", **opts))
      model = nonempty_str(Samagotchi::Config.resolve("recap.model", **opts))
      return nil if base_url.nil? && host_ref.nil? && model.nil?

      {
        host_ref: host_ref,
        base_url: base_url,
        model: model,
        inactivity: Samagotchi::Config.resolve("recap.inactivity", **opts),
        timeout: Samagotchi::Config.resolve("recap.timeout", **opts),
        min_user_turns: Samagotchi::Config.resolve("recap.min_user_turns", **opts)
      }
    end

    # Resolve the `memories:` section: the baseline list of memory entries
    # preloaded into the system prompt. Same shape as CLI `--memory` values:
    # bare names or `scope/name` refs. Accepts a YAML list of strings or a
    # single comma-separated string (commas inside list items are split too).
    # Returns [] when the section is absent, false, or malformed.
    def preloaded_memories(env: ENV, path: global_path(env: env))
      data = read_yaml(env: env, path: path)
      raw = data["memories"] if data.is_a?(Hash)
      return [] if raw.nil? || raw == false

      items = raw.is_a?(Array) ? raw : [raw]
      items.flat_map { |v| v.to_s.split(",") }.map(&:strip).reject(&:empty?)
    rescue StandardError
      []
    end

    # Parse a model string that may be qualified as "host_alias:model"
    # Returns [host_alias_or_nil, bare_model]
    def parse_host_qualified_model(raw, hosts: nil)
      value = raw.to_s.strip
      return [nil, value] if value.empty?
      # Try split on first ':' or '/' where prefix matches a known host
      hosts_map = hosts || {}
      # Normalize keys downcase
      lowered_keys = hosts_map.keys.map(&:downcase)
      # Check ':' split
      if value.include?(":")
        prefix, rest = value.split(":", 2)
        if lowered_keys.include?(prefix.strip.downcase) && !rest.strip.empty?
          return [prefix.strip.downcase, rest.strip]
        end
      end
      if value.include?("/")
        prefix, rest = value.split("/", 2)
        if lowered_keys.include?(prefix.strip.downcase) && !rest.strip.empty?
          return [prefix.strip.downcase, rest.strip]
        end
      end
      [nil, value]
    end

    def hosts_json_for_env(env: ENV, path: global_path(env: env))
      hosts = hosts_config(env: env, path: path)
      # Only serialize if non-default or explicitly configured hosts:
      # include when hosts file exists with hosts: section or when workers need propagation
      return nil if hosts.nil? || hosts.empty?
      # Serialize to JSON with string keys
      simple = hosts.transform_values { |v| { "host" => v[:host], "port" => v[:port], "transport" => v[:transport]&.to_s } }
      JSON.generate(simple)
    rescue StandardError
      nil
    end

    def write_default_model!(model_name, env: ENV, path: global_path(env: env))
      resolved = model_name.to_s.strip
      raise ArgumentError, "model name is required" if resolved.empty?

      if resolved.include?(":") || resolved.include?("/")
        sep = resolved.include?(":") ? ":" : "/"
        prefix = resolved.split(sep, 2).first.to_s.strip.downcase
        begin
          hosts = hosts_config(env: env, path: path)
          if hosts && !hosts.empty? && !hosts.key?(prefix) && prefix.match?(HOST_NAME_RE)
          end
        rescue StandardError
          nil
        end
      end

      raw_data = read_yaml(env: env, path: path) || {}

      # Migrate to new dotted nested form: default.model (Option A)
      raw_data["default"] ||= {}
      if raw_data["default"].is_a?(Hash)
        raw_data["default"]["model"] = resolved
      else
        raw_data["default"] = { "model" => resolved }
      end
      # Remove legacy UPPER key if present
      raw_data.delete(DEFAULT_MODEL_KEY)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp"
      File.write(tmp, YAML.dump(raw_data))
      File.rename(tmp, path)
      clear_yaml_cache!(path)
      env[DEFAULT_MODEL_KEY] = resolved
      # Also sync new Config store if loaded
      Samagotchi::Config.reload!(path: path, env: env, cli_overrides: {})
      true
    end

    def model_aliases(env: ENV, path: global_path(env: env))
      data = read_yaml(env: env, path: path)
      return {} unless data.is_a?(Hash)

      raw = data[MODEL_ALIASES_KEY]
      return {} if raw.nil?
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(k, v), result|
        key = k.to_s.strip
        next if key.empty?
        val = v.to_s.strip
        next if val.empty?

        result[key.downcase] = val
      end
    rescue StandardError
      {}
    end

    def resolve_model_alias(raw, env: ENV, path: global_path(env: env), hosts: nil)
      value = raw.to_s.strip
      return value if value.empty?

      aliases = model_aliases(env: env, path: path)
      # Host-qualified handling: "host:alias" -> "host:resolved"
      # This allows /model recap-box:small where "small" is an alias.
      if value.include?(":") || value.include?("/")
        hosts_map = hosts || hosts_config(env: env, path: path)
        host, bare = parse_host_qualified_model(value, hosts: hosts_map)
        if host && !bare.to_s.strip.empty?
          resolved_bare = aliases.fetch(bare.downcase, bare)
          # Preserve the separator the user used (: or /)
          sep = value.downcase.include?("#{host}:") ? ":" : (value.downcase.include?("#{host}/") ? "/" : ":")
          return "#{host}#{sep}#{resolved_bare}"
        end
      end

      aliases.fetch(value.downcase, value)
    end

    RESERVED_MODEL_ALIASES = %w[clear default none off].freeze

    def write_model_alias!(alias_name, model_name, env: ENV, path: global_path(env: env))
      alias_key = alias_name.to_s.strip
      raise ArgumentError, "alias name is required" if alias_key.empty?
      raise ArgumentError, "model name is required" if model_name.to_s.strip.empty?

      lowered_key = alias_key.downcase
      raise ArgumentError, "alias name '#{alias_key}' is reserved" if RESERVED_MODEL_ALIASES.include?(lowered_key)
      raise ArgumentError, "alias name must not contain whitespace" if alias_key.match?(/\s/)
      raise ArgumentError, "alias name must not start with '-'" if alias_key.start_with?("-")
      raise ArgumentError, "alias name must not contain '/'" if alias_key.include?("/")
      unless alias_key.match?(/\A[a-z0-9][a-z0-9._-]*\z/i)
        raise ArgumentError, "alias name must match /[a-z0-9][a-z0-9._-]*/i (got '#{alias_key}')"
      end

      resolved_model = model_name.to_s.strip
      raise ArgumentError, "alias must not point to itself" if lowered_key == resolved_model.downcase

      raw_data = read_yaml(env: env, path: path) || {}

      aliases_hash = raw_data[MODEL_ALIASES_KEY]
      unless aliases_hash.is_a?(Hash)
        aliases_hash = {}
        raw_data[MODEL_ALIASES_KEY] = aliases_hash
      end

      # Normalize existing alias keys to downcase to avoid duplicates like Qwen/qwen
      normalized = {}
      aliases_hash.each do |k, v|
        nk = k.to_s.strip.downcase
        next if nk.empty?
        normalized[nk] = v.to_s.strip unless v.to_s.strip.empty?
      end
      raw_data[MODEL_ALIASES_KEY] = normalized

      previous = normalized[lowered_key]
      normalized[lowered_key] = resolved_model

      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp"
      File.write(tmp, YAML.dump(raw_data))
      File.rename(tmp, path)
      clear_yaml_cache!(path)
      previous
    end

    def nonempty_str(value)
      str = value.to_s.strip
      str.empty? ? nil : str
    end
    private_class_method :nonempty_str
  end
end
