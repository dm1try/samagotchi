# frozen_string_literal: true

require "yaml"
require "json"
require "fileutils"
require "uri"
require "set"
require_relative "log"

module Samagotchi
  # Parses the thinking: levels of host and model entries (it needs Config).
  autoload :Thinking, File.expand_path("thinking", __dir__)

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
    Entry = Struct.new(:key, :yaml_path, :type, :default, :expose, :enum_values, :yaml_aliases, keyword_init: true) do
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
      # The prompt profile for every model in this process (ModelProfile::NAMES).
      # No config key: per-model and per-host profiles live in models: and hosts:.
      Entry.new(key: "model.profile",            yaml_path: %w[model profile],            type: :enum,   default: nil,              expose: %i[env cli], enum_values: %w[qwen36 gemma4]),
      Entry.new(key: "server.transport",         yaml_path: %w[server transport],          type: :enum,   default: "llama_cpp",     expose: %i[env config cli], enum_values: %w[llama_cpp mlx omlx]),
      Entry.new(key: "server.host",              yaml_path: %w[server host],               type: :string, default: "localhost",     expose: %i[env config cli]),
      Entry.new(key: "server.port",              yaml_path: %w[server port],               type: :integer, default: 8080,            expose: %i[env config cli]),
      Entry.new(key: "server.open_timeout",      yaml_path: %w[server open_timeout],       type: :integer, default: 10,              expose: %i[env config cli]),
      Entry.new(key: "server.read_timeout",      yaml_path: %w[server read_timeout],       type: :integer, default: 600,            expose: %i[env config cli]),
      # Seconds a streamed answer may take to show its first text, reasoning
      # or tool call, for every host; 0 = off. Unset: 120 on remote hosts,
      # off on local ones. hosts.<name>.first_token_timeout wins.
      Entry.new(key: "server.first_token_timeout", yaml_path: %w[server first_token_timeout], type: :integer, default: nil,          expose: %i[env config]),

      Entry.new(key: "recap.enabled",            yaml_path: %w[recap enabled],             type: :bool,   default: nil,              expose: %i[env config]),
      Entry.new(key: "recap.model",              yaml_path: %w[recap model],               type: :string, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "recap.base_url",           yaml_path: %w[recap base_url],            type: :string, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "recap.host_ref",           yaml_path: %w[recap host_ref],            type: :string, default: nil,              expose: %i[env config cli], yaml_aliases: %w[host]),
      Entry.new(key: "recap.inactivity",         yaml_path: %w[recap inactivity],          type: :float,   default: nil,             expose: %i[env config cli]),
      Entry.new(key: "recap.timeout",            yaml_path: %w[recap timeout],             type: :float,   default: nil,             expose: %i[env config cli]),
      Entry.new(key: "recap.min_user_turns",     yaml_path: %w[recap min_user_turns],      type: :integer, default: nil,             expose: %i[env config cli]),
      # "N-M" or "N" sentences (1-10); unset = 2-4. Parsed by RecapPrompt.sentences_range.
      Entry.new(key: "recap.sentences",          yaml_path: %w[recap sentences],           type: :string,  default: nil,             expose: %i[env config cli]),

      Entry.new(key: "session.retention_days",        yaml_path: %w[session retention_days],        type: :integer, default: 14,   expose: %i[env config cli]),
      Entry.new(key: "session.max_count",             yaml_path: %w[session max_count],             type: :integer, default: 500,  expose: %i[env config cli]),
      Entry.new(key: "session.keep_status",           yaml_path: %w[session keep_status],           type: :string, default: "running", expose: %i[env config cli]),
      Entry.new(key: "session.sweep_interval_hours",  yaml_path: %w[session sweep_interval_hours],  type: :integer, default: 24,   expose: %i[env config cli]),
      Entry.new(key: "session.idle_exit_minutes",     yaml_path: %w[session idle_exit_minutes],     type: :float,   default: 30.0, expose: %i[env config cli]),
      # Plain `chi` runs like `chi --shared` (bin/chi, LaunchMode); false, or --no-shared per run, keeps the plain REPL. No CLI flag: that would duplicate --shared.
      Entry.new(key: "session.shared",                yaml_path: %w[session shared],                type: :bool,    default: true,  expose: %i[env config]),
      # false: a session nothing happened in is deleted when it is left (SessionManager.empty_session?).
      Entry.new(key: "session.keep_empty",            yaml_path: %w[session keep_empty],            type: :bool,    default: false, expose: %i[env config]),
      # The most sessions one session may have delegated and still running (the delegate tool); a guard against a runaway model.
      Entry.new(key: "session.max_children",          yaml_path: %w[session max_children],          type: :integer, default: 4,     expose: %i[env config]),

      # Images sent to a model (ImageStore): the long side they are downscaled
      # to, the most bytes one may take (bigger → re-encoded as jpeg), and how
      # many one request carries (older ones become placeholders).
      Entry.new(key: "image.max_side",           yaml_path: %w[image max_side],           type: :integer, default: 1568,            expose: %i[env config]),
      Entry.new(key: "image.max_bytes",          yaml_path: %w[image max_bytes],          type: :integer, default: 3_750_000,       expose: %i[env config]),
      Entry.new(key: "image.max_per_request",    yaml_path: %w[image max_per_request],    type: :integer, default: 20,              expose: %i[env config]),

      Entry.new(key: "guardrails.enabled",       yaml_path: %w[guardrails enabled],       type: :bool,   default: true,             expose: %i[env config]),

      Entry.new(key: "log.file",                 yaml_path: %w[log file],                 type: :string, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "log.disable",              yaml_path: %w[log disable],              type: :bool,   default: false,            expose: %i[env config cli]),
      # debug adds payload dumps (model responses, tool args/results) and fetch lines.
      Entry.new(key: "log.level",                yaml_path: %w[log level],                type: :enum,   default: "info",           expose: %i[env config cli], enum_values: %w[debug info warn error]),

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
      Entry.new(key: "thinking.render_interval", yaml_path: %w[thinking render_interval], type: :float,   default: 0.08,            expose: %i[env config cli]),
      Entry.new(key: "thinking.turn_preamble",   yaml_path: %w[thinking turn_preamble],   type: :bool,   default: true,             expose: %i[env config cli]),
      # How much models think: off|low|medium|high|default, parsed by Thinking
      # (a :string, since YAML reads an unquoted off as false). The CLI flag
      # is bin/chi's own --thinking; models: and hosts: entries rank below
      # the flag and the env, above config.yml's value.
      Entry.new(key: "thinking.level",           yaml_path: %w[thinking level],           type: :string, default: "default",       expose: %i[env config]),

      Entry.new(key: "default.n_predict",        yaml_path: %w[default n_predict],        type: :integer, default: nil,              expose: %i[env config cli]),
      Entry.new(key: "max_tool_output_chars",    yaml_path: %w[max_tool_output_chars],    type: :integer, default: 10_000,          expose: %i[env config cli]),

      Entry.new(key: "retry.max",                yaml_path: %w[retry max],                type: :integer, default: 5,               expose: %i[env config cli]),
      Entry.new(key: "retry.base_delay",         yaml_path: %w[retry base_delay],         type: :float,   default: 0.5,             expose: %i[env config cli]),
      Entry.new(key: "retry.max_delay",          yaml_path: %w[retry max_delay],          type: :float,   default: 8.0,             expose: %i[env config cli]),
      # Asks again in the same turn after an empty answer (EmptyAnswerRetry);
      # 0 = off, capped at 3. No CLI flag: workers get no CLI args.
      Entry.new(key: "retry.empty_answer",       yaml_path: %w[retry empty_answer],       type: :integer, default: 1,               expose: %i[env config]),
      # What `chi update` touches; its --no-gem/--no-bundles/--no-desktop turn one off for a run.
      Entry.new(key: "update.gem",               yaml_path: %w[update gem],               type: :bool,    default: true,            expose: %i[env config]),
      Entry.new(key: "update.bundles",           yaml_path: %w[update bundles],           type: :bool,    default: true,            expose: %i[env config]),
      Entry.new(key: "update.desktop",           yaml_path: %w[update desktop],           type: :bool,    default: true,            expose: %i[env config]),

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
      # The page shows each turn as one block of generations (the live one at the bottom); false brings back the row of bubbles; ?view=turn|chat overrides it per page load.
      Entry.new(key: "web.turn_view",            yaml_path: %w[web turn_view],            type: :bool,    default: true,           expose: %i[env config cli]),
      # Quick replies next to Annotate in the page's selection bubble, "|"-separated (a YAML list works too); "" leaves only Annotate.
      Entry.new(key: "web.annotate_presets",     yaml_path: %w[web annotate_presets],     type: :string, default: "Agreed|Could you please elaborate?", expose: %i[env config cli]),

      Entry.new(key: "no_interrupt",             yaml_path: %w[no_interrupt],             type: :bool,   default: false,            expose: %i[env config cli]),
      Entry.new(key: "no_default_input",         yaml_path: %w[no_default_input],         type: :bool,   default: false,            expose: %i[env config cli]),

      # env+config only
      Entry.new(key: "default.input",            yaml_path: %w[default input],            type: :string, default: nil,              expose: %i[env config]),
      Entry.new(key: "history.file",             yaml_path: %w[history file],             type: :string, default: nil,              expose: %i[env config]),
      Entry.new(key: "skip_agent_md",            yaml_path: %w[skip_agent_md],            type: :bool,   default: false,            expose: %i[env config]),
    ].freeze

    # Top-level maps read by their own code, whose entry names and contents
    # are the user's: ConfigFile.model_aliases / preloaded_memories,
    # Hooks::Loader, Engine#read_bundle_settings.
    FREE_FORM_MAPS = %w[model_aliases hooks bundles memories].freeze
    # Maps of named entries and the keys an entry may hold
    # (ConfigFile.hosts_config, ConfigFile.model_settings).
    MAP_ENTRY_KEYS = {
      "hosts" => %w[host port url transport api api_key_env profile first_token_timeout vision sampling thinking enabled].freeze,
      "models" => %w[profile vision sampling thinking].freeze
    }.freeze
    # Section keys beyond the registry's: guardrails' YAML rules (Engine#guardrail_rules).
    SECTION_EXTRA_KEYS = { "guardrails" => %w[rules disable].freeze }.freeze
    # Removed settings that warn on their own (Engine.warn_removed_backend_setting).
    REMOVED_KEYS = %w[backend].freeze

    # Fast lookup maps
    BY_KEY = ENTRIES.each_with_object({}) { |e, h| h[e.key] = e }.freeze
    BY_ENV = ENTRIES.each_with_object({}) { |e, h| h[e.env_key] = e }.freeze

    class << self
      # The +candidates+ within edit distance 2 of +probe+, closest first
      # (the "did you mean" of an unknown key or host).
      def near_names(probe, candidates)
        candidates.uniq.map { |c| [levenshtein(probe, c), c] }.select { |d, _| d <= 2 }.sort.map(&:last)
      end

      def find_by_key(key)
        BY_KEY[key.to_s]
      end

      def find_by_env(env_key)
        BY_ENV[env_key.to_s]
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
        # For string, preserve as-is (including trailing spaces like "Please ")
        if entry.type == :string
          # A YAML list for a "|"-separated setting (web.annotate_presets).
          str = raw.is_a?(Array) ? raw.join("|") : raw.to_s
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
              Log.warn(:config, "invalid_value", echo: "Warning: invalid integer for #{entry.key} (#{entry.env_key}): #{raw.inspect} — using default", key: entry.key)
              return entry.default
            end
          end
        when :float
          val = Float(str, exception: false)
          if val.nil?
            Log.warn(:config, "invalid_value", echo: "Warning: invalid float for #{entry.key}: #{raw.inspect}", key: entry.key)
            return entry.default
          end
          val
        when :bool
          case str.downcase
          when "1", "true", "yes", "on" then true
          when "0", "false", "no", "off", "" then false
          else
            Log.warn(:config, "invalid_value", echo: "Warning: invalid bool for #{entry.key}: #{raw.inspect} — treating as false", key: entry.key)
            false
          end
        when :enum
          lowered = str.downcase
          allowed = entry.enum_values.map(&:downcase)
          unless allowed.include?(lowered)
            Log.warn(:config, "invalid_value", echo: "Warning: invalid value for #{entry.key}: #{raw.inspect} (allowed: #{entry.enum_values.join(', ')}) — using default", key: entry.key)
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

      # Lookup yaml_path in nested hash, accepting snake leaf, kebab alias and
      # entry-specific yaml_aliases, then legacy flat UPPER keys (e.g.,
      # SAMAGOTCHI_DEFAULT_MODEL) for transition: the nested key wins when a
      # file has both (ConfigFile.load_global_env! warns about that).
      def lookup_yaml(data, yaml_path)
        entry = ENTRIES.find { |e| e.yaml_path == yaml_path }
        nested = lookup_nested(data, yaml_path, entry)
        return nested unless nested.nil?

        lookup_legacy(data, entry)
      end

      # The legacy flat key's value for +entry+, or nil.
      def lookup_legacy(data, entry)
        return nil unless entry && data.is_a?(Hash)

        key = entry.env_key
        return data[key] if data.key?(key)
        return data[key.to_sym] if data.key?(key.to_sym)

        nil
      end

      # The nested key's value for +yaml_path+, or nil.
      def lookup_nested(data, yaml_path, entry = nil)
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
      ensure
        # The log resolves its file and level from here.
        Samagotchi::Log.invalidate! if defined?(Samagotchi::Log)
      end

      def cli_overrides
        @cli_overrides ||= {}
      end

      def get(key)
        get_with_origin(key).first
      end

      # A timeout setting (server.open_timeout, server.read_timeout) in
      # seconds, +given+ (a caller's own value) first; one that isn't
      # positive (0, a word) is the key's default, on every kind of host.
      def positive_seconds(key, given = nil)
        value = (given.nil? ? get(key) : given).to_i
        value.positive? ? value : find_by_key(key).default
      rescue StandardError
        find_by_key(key)&.default
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

      # Problems with the keys of a parsed config.yml, one message per key the
      # code doesn't read (with a "did you mean" when a known key is close).
      # Every config-exposed entry in ENTRIES is known as written; names under
      # the maps are the user's, and host/model entries may hold the keys
      # their readers take. Legacy flat keys warn in ConfigFile.load_global_env!.
      def validate_yaml_sections(data)
        return [] unless data.is_a?(Hash)

        data.flat_map do |key, value|
          key = key.to_s
          if find_by_env(key)&.config_exposed? || FREE_FORM_MAPS.include?(key) || REMOVED_KEYS.include?(key)
            []
          elsif MAP_ENTRY_KEYS.key?(key)
            map_entry_problems(key, value)
          elsif value.is_a?(Hash) && (known_sections.include?(key) || ENTRIES.any? { |e| e.yaml_path.size > 1 && e.section == key })
            value.keys.filter_map { |leaf| key_problem("#{key}.#{leaf}") }
          elsif known_sections.include?(key)
            # An all-commented section is nil; recap: false turns recaps off.
            value.nil? || (key == "recap" && value == false) ? [] : ["config: '#{key}' must be a mapping of settings; ignored"]
          else
            [key_problem(key)].compact
          end
        end
      end

      # Dotted keys config.yml may set: config-exposed entries (snake and kebab
      # leaf, yaml_aliases), the extra section keys and the map names.
      def known_config_keys
        @known_config_keys ||= ENTRIES.select(&:config_exposed?).flat_map do |entry|
          *section, leaf = entry.yaml_path
          [leaf, leaf.tr("_", "-"), *Array(entry.yaml_aliases)].map { |l| [*section, l].join(".") }
        end.to_set.merge(SECTION_EXTRA_KEYS.flat_map { |s, leaves| leaves.map { |l| "#{s}.#{l}" } })
                                .merge(FREE_FORM_MAPS).merge(MAP_ENTRY_KEYS.keys).freeze
      end

      private

      def known_sections
        @known_sections ||= known_config_keys.filter_map { |k| k.split(".").first if k.include?(".") }.to_set.freeze
      end

      # nil when +dotted+ is a key the file may hold.
      def key_problem(dotted)
        return nil if known_config_keys.include?(dotted)

        entry = find_by_key(dotted) || find_by_env(dotted)
        if entry
          where = entry.cli_exposed? ? "#{entry.env_key} or #{entry.cli_flag}" : entry.env_key
          return "config: '#{dotted}' can't be set in config.yml; use #{where}"
        end

        canonical = ENTRIES.select(&:config_exposed?).map(&:key) + known_sections.to_a +
                    SECTION_EXTRA_KEYS.flat_map { |s, leaves| leaves.map { |l| "#{s}.#{l}" } } + FREE_FORM_MAPS + MAP_ENTRY_KEYS.keys
        # A legacy-looking flat key compares by its nested form.
        probe = dotted.start_with?("SAMAGOTCHI_") ? dotted.delete_prefix("SAMAGOTCHI_").downcase : dotted
        unknown_key_message(dotted, probe, canonical)
      end

      def map_entry_problems(map, value)
        return [] unless value.is_a?(Hash)

        allowed = MAP_ENTRY_KEYS.fetch(map)
        value.flat_map do |name, entry|
          next [] unless entry.is_a?(Hash)

          (entry.keys.map(&:to_s) - allowed).map do |k|
            unknown_key_message("#{map}.#{name}.#{k}", k, allowed, prefix: "#{map}.#{name}.")
          end
        end
      end

      # "config: unknown key 'x'", with a "did you mean" naming the candidates
      # within edit distance 2 of +probe+ (closest first) and the ones that
      # share its last segment, at most three.
      def unknown_key_message(key, probe, candidates, prefix: "")
        candidates = candidates.uniq
        near = near_names(probe, candidates)
        close = (near + candidates.select { |c| c.split(".").last == probe.split(".").last }).uniq.first(3)
        hint = close.empty? ? "" : " (did you mean #{close.map { |c| "'#{prefix}#{c}'" }.join(' or ')}?)"
        "config: unknown key '#{key}'#{hint}"
      end

      def levenshtein(a, b)
        prev = (0..b.size).to_a
        a.each_char.with_index(1) do |ca, i|
          cur = [i]
          b.each_char.with_index(1) do |cb, j|
            cur << [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca == cb ? 0 : 1)].min
          end
          prev = cur
        end
        prev.last
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
    MODELS_KEY = "models"

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

    # Print +message+ to stderr unless this process already did. The config
    # is read again for every HostRegistry, worker env and model lookup, so a
    # warning about the file would otherwise repeat several times per run.
    def warn_once(message)
      @warn_once_mutex ||= Mutex.new
      first = @warn_once_mutex.synchronize { (@warned ||= Set.new).add?(message) }
      Samagotchi::Log.warn(:config, "config_warning", echo: message) if first
    end

    # A `vision:` setting (hosts entry or models: entry): true, false, or nil
    # when unset. Anything else warns once and counts as unset.
    def vision_flag(value, where)
      return nil if value.nil?
      return value if value == true || value == false

      text = value.to_s.strip.downcase
      return true if text == "true"
      return false if text == "false"

      warn_once "Warning: #{where}: vision must be true or false; ignored"
      nil
    end

    # Request keys chi sets itself; a `sampling:` map can't override them.
    # (Length caps would need their own semantics.)
    SAMPLING_RESERVED_KEYS = %w[model messages prompt stream stream_options tools tool_choice stop n_predict
                                max_tokens n parallel_tool_calls response_format cache_prompt].freeze

    # A `sampling:` setting (hosts entry or models: entry): request parameters
    # passed through to the provider as written (keys symbolized, nested maps
    # too, so e.g. chat_template_kwargs works). A null value means "don't
    # send it" (drops chi's own temperature default). Not a map: warns once,
    # nil. Reserved keys warn once and are dropped. nil when nothing is left.
    def sampling_map(value, where)
      return nil if value.nil?
      unless value.is_a?(Hash)
        warn_once "Warning: #{where}: sampling must be a map of request parameters; ignored"
        return nil
      end

      result = value.each_with_object({}) do |(raw_key, raw_value), acc|
        key = raw_key.to_s.strip
        next if key.empty?
        if SAMPLING_RESERVED_KEYS.include?(key)
          warn_once "Warning: #{where}: sampling.#{key} is set by chi; ignored"
          next
        end
        acc[key.to_sym] = deep_symbolize(raw_value)
      end
      result.empty? ? nil : result.freeze
    end

    def deep_symbolize(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_s.to_sym, deep_symbolize(v)] }.freeze
      when Array then value.map { |v| deep_symbolize(v) }.freeze
      else value
      end
    end

    # Forget the warnings already printed (specs).
    def reset_warnings!
      @warned = nil
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
        Samagotchi::Config.validate_yaml_sections(raw).each { |w| Log.warn(:config, "config_key", echo: "Warning: #{w}") }
        # Warn on legacy UPPER keys; the nested key wins when both are set.
        # Any other flat key is unknown to validate_yaml_sections.
        raw.each_key do |k|
          entry = Samagotchi::Config.find_by_env(k)
          next unless entry&.config_exposed?

          if !Samagotchi::Config.lookup_nested(raw, entry.yaml_path, entry).nil?
            nested = entry.yaml_path.join(".")
            Log.warn(:config, "legacy_key", echo: "Warning: config: both '#{k}' and '#{nested}' are set; using '#{nested}', remove the flat key", key: k.to_s)
          else
            Log.warn(:config, "legacy_key", echo: "Warning: config key '#{k}' is legacy UPPER — use '#{entry.yaml_path.join('.')}'", key: k.to_s)
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
        # The env's thinking.level outranks models:/hosts: levels, the file's doesn't (Thinking.resolve).
        next if entry.key == "thinking.level"
        # check if file actually contained this key (including legacy flat)
        file_val = Samagotchi::Config.lookup_yaml(raw, entry.yaml_path)
        file_val ||= raw[entry.env_key] if raw.key?(entry.env_key)
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
    # How chi talks to a host: a raw-prompt api (also the Client transport) or
    # openai, the chat loop against <host>/v1.
    VALID_APIS_FOR_CONFIG = (VALID_TRANSPORTS_FOR_CONFIG + %w[openai]).freeze
    HOST_NAME_RE = /\A[a-z0-9][a-z0-9._-]*\z/i
    ENV_NAME_RE = /\A[A-Za-z_][A-Za-z0-9_]*\z/

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
            warn_once "Warning: ignoring hosts entry '#{name}': must match /[a-z0-9][a-z0-9._-]*/i"
            next
          end
          lowered = name.downcase
          unless raw_cfg.is_a?(Hash)
            warn_once "Warning: ignoring hosts entry '#{name}': expected mapping"
            next
          end
          host = raw_cfg["host"] || raw_cfg[:host]
          port = raw_cfg["port"] || raw_cfg[:port]
          transport = raw_cfg["transport"] || raw_cfg[:transport]
          api = raw_cfg["api"] || raw_cfg[:api]
          enabled = raw_cfg.key?("enabled") ? raw_cfg["enabled"] : (raw_cfg.key?(:enabled) ? raw_cfg[:enabled] : true)
          if enabled == false || enabled.to_s.strip.downcase == "false"
            next
          end
          url = (raw_cfg["url"] || raw_cfg[:url]).to_s.strip
          api_key_env = (raw_cfg["api_key_env"] || raw_cfg[:api_key_env]).to_s.strip
          # Kept as written; ModelProfile.resolve warns about an unknown one.
          profile = (raw_cfg["profile"] || raw_cfg[:profile]).to_s.strip.downcase
          first_token_timeout = raw_cfg.key?("first_token_timeout") ? raw_cfg["first_token_timeout"] : raw_cfg[:first_token_timeout]
          vision = ConfigFile.vision_flag(raw_cfg.key?("vision") ? raw_cfg["vision"] : raw_cfg[:vision], "hosts entry '#{name}'")
          sampling = ConfigFile.sampling_map(raw_cfg.key?("sampling") ? raw_cfg["sampling"] : raw_cfg[:sampling], "hosts entry '#{name}'")
          thinking = Thinking.level(raw_cfg.key?("thinking") ? raw_cfg["thinking"] : raw_cfg[:thinking], "hosts entry '#{name}'")
          unless first_token_timeout.nil? || (first_token_timeout.is_a?(Numeric) && !first_token_timeout.negative?)
            warn_once "Warning: hosts entry '#{name}': first_token_timeout must be seconds (0 = off); using the default"
            first_token_timeout = nil
          end
          unless api_key_env.empty? || api_key_env.match?(ENV_NAME_RE)
            warn_once "Warning: ignoring hosts entry '#{name}': api_key_env must be an environment variable name"
            next
          end
          scheme = "http"
          unless url.empty?
            unless host.to_s.strip.empty? && port.to_s.strip.empty?
              warn_once "Warning: ignoring hosts entry '#{name}': give url or host/port, not both"
              next
            end
            uri = begin
              URI.parse(url)
            rescue URI::InvalidURIError
              nil
            end
            unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
              warn_once "Warning: ignoring hosts entry '#{name}': url must be an http(s) URL"
              next
            end
            host = uri.host
            port = uri.port
            scheme = uri.scheme
            url = url.chomp("/")
          end
          host = host.to_s.strip
          if host.empty?
            warn_once "Warning: ignoring hosts entry '#{name}': host is required"
            next
          end
          port_val = port.to_s.strip.empty? ? 8080 : port.to_i
          if port_val <= 0 || port_val > 65535
            warn_once "Warning: ignoring hosts entry '#{name}': invalid port"
            next
          end
          transport_val = transport.to_s.strip.downcase
          if transport_val.empty?
            transport_val = nil
          elsif !VALID_TRANSPORTS_FOR_CONFIG.include?(transport_val)
            warn_once "Warning: ignoring hosts entry '#{name}': unknown transport '#{transport_val}'"
            next
          end
          api_val = api.to_s.strip.downcase
          if api_val.empty?
            api_val = nil
          elsif !VALID_APIS_FOR_CONFIG.include?(api_val)
            warn_once "Warning: ignoring hosts entry '#{name}': unknown api '#{api_val}'"
            next
          elsif VALID_TRANSPORTS_FOR_CONFIG.include?(api_val)
            # A raw-prompt api is the transport; a different transport contradicts it.
            if transport_val && transport_val != api_val
              warn_once "Warning: ignoring hosts entry '#{name}': api '#{api_val}' conflicts with transport '#{transport_val}'"
              next
            end
            transport_val = api_val
          end
          normalized[lowered] = { name: lowered, host: host, port: port_val, transport: transport_val ? transport_val.to_sym : nil,
                                  api: api_val&.to_sym, original_name: name, scheme: scheme,
                                  url: url.empty? ? nil : url, api_key_env: api_key_env.empty? ? nil : api_key_env,
                                  profile: profile.empty? ? nil : profile, first_token_timeout: first_token_timeout,
                                  vision: vision, sampling: sampling, thinking: thinking }
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
        min_user_turns: Samagotchi::Config.resolve("recap.min_user_turns", **opts),
        sentences: Samagotchi::Config.resolve("recap.sentences", **opts)
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

    # Hosted providers' names, which no local model family uses: as a
    # prefix they always mean a host ("openai:gpt-4o"). "mistral" and
    # "deepseek" are left out: Ollama has mistral:7b and deepseek-* tags.
    PROVIDER_HOST_NAMES = %w[openrouter openai anthropic google gemini groq xai together fireworks].freeze

    # The host a model ref names when that host isn't configured, or nil.
    # A ':' in a model id is often a tag (qwen3:8b, org/model:Q4_K_M), so
    # the prefix counts as a host only when it could be a host name and
    # either the rest looks like a hosted provider's org/model id
    # ("nosuch:anthropic/claude-sonnet-4"; Ollama-style tags never hold a
    # '/') or the prefix is a provider's name (PROVIDER_HOST_NAMES).
    def unknown_host_prefix(raw, hosts:)
      prefix, rest = raw.to_s.strip.split(":", 2)
      return nil if rest.to_s.strip.empty? || !prefix.match?(HOST_NAME_RE)
      return nil unless rest.include?("/") || PROVIDER_HOST_NAMES.include?(prefix.downcase)

      prefix = prefix.downcase
      hosts.keys.map { |k| k.to_s.downcase }.include?(prefix) ? nil : prefix
    end

    def hosts_json_for_env(env: ENV, path: global_path(env: env))
      hosts = hosts_config(env: env, path: path)
      # Only serialize if non-default or explicitly configured hosts:
      # include when hosts file exists with hosts: section or when workers need propagation
      return nil if hosts.nil? || hosts.empty?
      # Serialize to JSON with string keys
      simple = hosts.transform_values do |v|
        # A url entry travels as its url (host/port come from it); the API
        # key stays in the environment, which workers inherit.
        location = v[:url] ? { "url" => v[:url] } : { "host" => v[:host], "port" => v[:port] }
        location.merge("transport" => v[:transport]&.to_s, "api" => v[:api]&.to_s, "api_key_env" => v[:api_key_env],
                       "profile" => v[:profile], "first_token_timeout" => v[:first_token_timeout],
                       "vision" => v[:vision], "sampling" => v[:sampling], "thinking" => v[:thinking]&.to_s).compact
      end
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

    # The top-level `models:` map: per-model settings keyed by model id or
    # alias (downcased), e.g. `models: {my-alias: {profile: qwen36}}`. Values are
    # kept as written (profile downcased; ModelProfile.resolve validates it);
    # an entry that is not a map is skipped.
    def model_settings(env: ENV, path: global_path(env: env))
      data = read_yaml(env: env, path: path)
      raw = data[MODELS_KEY] if data.is_a?(Hash)
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(k, v), result|
        key = k.to_s.strip.downcase
        next if key.empty? || !v.is_a?(Hash)

        profile = (v["profile"] || v[:profile]).to_s.strip.downcase
        vision = vision_flag(v.key?("vision") ? v["vision"] : v[:vision], "models: #{key}")
        result[key] = { profile: profile.empty? ? nil : profile }
        result[key][:vision] = vision unless vision.nil?
        sampling = sampling_map(v.key?("sampling") ? v["sampling"] : v[:sampling], "models: #{key}")
        result[key][:sampling] = sampling if sampling
        thinking = Thinking.level(v.key?("thinking") ? v["thinking"] : v[:thinking], "models: #{key}")
        result[key][:thinking] = thinking if thinking
      end
    rescue StandardError
      {}
    end

    # The first +names+ (model as typed, alias-resolved, bare, …) whose
    # models: entry sets +field+: [key, value], or nil. VisionSupport and
    # SamplingSettings look a model up the same way.
    def model_setting(names, field, models: nil)
      models ||= model_settings
      Array(names).map { |name| name.to_s.strip.downcase }.reject(&:empty?).uniq.each do |key|
        value = models.dig(key, field)
        return [key, value] unless value.nil?
      end
      nil
    end

    def resolve_model_alias(raw, env: ENV, path: global_path(env: env), hosts: nil)
      value = raw.to_s.strip
      return value if value.empty?

      aliases = model_aliases(env: env, path: path)
      # Host-qualified handling: "host:alias" -> "host:resolved"
      # This allows /model small-box:small where "small" is an alias.
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
