# frozen_string_literal: true

require "yaml"
require "json"
require "fileutils"

module Samagotchi
  module ConfigFile
    XDG_CONFIG_HOME_ENV = "XDG_CONFIG_HOME"
    CONFIG_DIR = "samagotchi"
    CONFIG_FILE = "config.yml"
    DEFAULT_MODEL_KEY = "SAMAGOTCHI_DEFAULT_MODEL"
    MODEL_ALIASES_KEY = "model_aliases"

    module_function

    # New unified loader: delegates to Samagotchi::Config registry.
    # Breaking: YAML now expects lower snake dotted paths (default.model)
    # instead of UPPER scalar keys. For compatibility, UPPER keys are warned
    # and ignored — env wins over file as before, now via registry precedence
    # (CLI > ENV > file > default). Returns true if file existed.
    def load_global_env!(env: ENV, path: global_path(env: env))
      require_relative "config"
      existed = File.file?(path)
      # Load snapshot with precedence CLI(∅) > ENV > file
      snapshot = Samagotchi::Config.load_snapshot(path: path, env: env, cli_overrides: {})
      # Validate sections for '_' misuse
      if existed
        begin
          raw = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
          if raw.is_a?(Hash)
            Samagotchi::Config.validate_yaml_sections(raw).each { |w| warn "Warning: #{w}" }
            # Warn on legacy UPPER keys
            raw.each_key do |k|
              if k.to_s.match?(/\A[A-Z_]{2,}\z/) && k.to_s.start_with?("SAMAGOTCHI_")
                warn "Warning: config key '#{k}' is legacy UPPER — use '#{k.to_s.downcase.sub(/^samagotchi_/, '').tr('_', '.')}' (e.g., default.model)"
              end
            end
          end
        rescue StandardError
          nil
        end
      end
      # For process-wide access, prime the Config store (so Config.get works)
      Samagotchi::Config.reload!(path: path, env: env, cli_overrides: {})
      # Keep ENV in sync for any code still reading ENV directly (transition)
      # Only for keys that were actually present in file (not defaults) to avoid polluting ENV with defaults
      if existed
        begin
          raw = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
          raw = {} unless raw.is_a?(Hash)
        rescue StandardError
          raw = {}
        end
        Samagotchi::Config.all_entries.each do |entry|
          next unless entry.env_exposed?
          # check if file actually contained this key (including legacy flat)
          file_val = Samagotchi::Config.lookup_yaml(raw, entry.yaml_path) rescue nil
          # also consider legacy flat env_key as file presence
          file_val ||= raw[entry.env_key] if raw.key?(entry.env_key)
          Array(entry.aliases).each { |a| file_val ||= raw[a] if raw.key?(a) }
          next if file_val.nil?
          val = snapshot[entry.key]
          next if val.nil?
          env[entry.env_key] = val.to_s unless env.key?(entry.env_key)
        end
      end
      existed
    end

    def global_path(env: ENV)
      config_home = env.fetch(XDG_CONFIG_HOME_ENV, "").to_s.strip
      base_dir = config_home.empty? ? File.expand_path("~/.config") : config_home
      File.join(base_dir, CONFIG_DIR, CONFIG_FILE)
    end

    def parse_file(path)
      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      return {} if data.nil?

      unless data.is_a?(Hash)
        raise ArgumentError, "global config must be a YAML mapping: #{path}"
      end

      # Legacy path: return flattened dotted keys for registry-compatible file,
      # plus warn on legacy UPPER scalar keys. For maps (hosts/hooks) keep as-is
      # — callers handle them separately. This keeps ConfigFile.hosts_config etc.
      # working while new Config handles scalars.
      result = {}
      flatten_for_parse(data, [], result)
      result
    end

    def flatten_for_parse(hash, prefix, result)
      hash.each do |k, v|
        full = (prefix + [k.to_s]).join(".")
        if v.is_a?(Hash)
          # Preserve maps like hosts/hooks/model_aliases as non-scalar skip for old callers
          # but also recurse for new dotted leaves so hosts_config still works via direct YAML read
          flatten_for_parse(v, prefix + [k.to_s], result) if prefix.empty? && %w[default recap server session log status context thinking read execute web].include?(k.to_s)
          next
        end
        next if v.nil?
        unless scalar_value?(v)
          next
        end
        result[full] = v.to_s
      end
    end
    private_class_method :flatten_for_parse

    def scalar_value?(value)
      value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
    end
    private_class_method :scalar_value?

    HOSTS_KEY = "hosts"
    RECAP_KEY = "recap"
    VALID_TRANSPORTS_FOR_CONFIG = %w[llama_cpp mlx omlx].freeze
    HOST_NAME_RE = /\A[a-z0-9][a-z0-9._-]*\z/i

    def hosts_config(env: ENV, path: global_path(env: env))
      raw_hosts = nil
      if File.file?(path)
        begin
          data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
          raw_hosts = data[HOSTS_KEY] if data.is_a?(Hash)
        rescue StandardError
          raw_hosts = nil
        end
      end

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

      # Backward compat: if no hosts defined, synthesize "default" from LLAMA_HOST/PORT
      if normalized.empty?
        default_host = env.fetch("LLAMA_HOST", "localhost").to_s.strip
        default_host = "localhost" if default_host.empty?
        default_port = env.fetch("LLAMA_PORT", "8080").to_s.strip
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

    def recap_config(env: ENV, path: global_path(env: env))
      raw_recap = nil
      if File.file?(path)
        begin
          data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
          raw_recap = data[RECAP_KEY] if data.is_a?(Hash)
        rescue StandardError
          raw_recap = nil
        end
      end
      # Explicit false disables
      return false if raw_recap == false
      return nil if raw_recap.nil? && env["SAMAGOTCHI_RECAP_BASE_URL"].to_s.strip.empty? && env["SAMAGOTCHI_RECAP_MODEL"].to_s.strip.empty?

      if raw_recap.is_a?(Hash)
        host_ref = (raw_recap["host_ref"] || raw_recap[:host_ref] || raw_recap["host"] || raw_recap[:host]).to_s.strip
        host_ref = nil if host_ref.empty?
        base_url = (raw_recap["base_url"] || raw_recap[:base_url]).to_s.strip
        base_url = nil if base_url.empty?
        model = (raw_recap["model"] || raw_recap[:model]).to_s.strip
        model = nil if model.empty?
        enabled = raw_recap.key?("enabled") ? raw_recap["enabled"] : (raw_recap.key?(:enabled) ? raw_recap[:enabled] : nil)
        if enabled == false || enabled.to_s.strip.downcase == "false"
          return false
        end
        inactivity = raw_recap["inactivity"] || raw_recap[:inactivity]
        timeout = raw_recap["timeout"] || raw_recap[:timeout]
        min_user_turns = raw_recap["min_user_turns"] || raw_recap[:min_user_turns]
        # If recap hash present but neither host_ref/base_url+model is configured, return raw for fallback handling
        if host_ref || base_url || model
          return { host_ref: host_ref, base_url: base_url, model: model, inactivity: inactivity, timeout: timeout, min_user_turns: min_user_turns }
        end
      elsif raw_recap == true
        # recap: true -> fall through to env vars
      end
      nil
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

      raw_data = {}
      if File.file?(path)
        loaded = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
        raw_data = loaded if loaded.is_a?(Hash)
      end

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
      env[DEFAULT_MODEL_KEY] = resolved
      # Also sync new Config store if loaded
      begin
        require_relative "config"
        Samagotchi::Config.reload!(path: path, env: env, cli_overrides: {})
      rescue StandardError
        nil
      end
      true
    end

    def model_aliases(env: ENV, path: global_path(env: env))
      return {} unless File.file?(path)

      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
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

      raw_data = {}
      if File.file?(path)
        loaded = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
        raw_data = loaded if loaded.is_a?(Hash)
      end

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
      previous
    end
  end
end
