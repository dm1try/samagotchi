# frozen_string_literal: true

require "uri"
require_relative "config"
require_relative "host_model"
require_relative "llm_context_strategy"

module Samagotchi
  # One config.yml hosts: entry, parsed and checked (ConfigFile.hosts_config
  # holds them by lowercased name; HostRegistry builds its HostEntry from
  # one).
  #
  # name: the lowercased entry name; host, port, scheme: where it is (from
  # url: when given); url: the configured url, nil when host/port; transport,
  # api: symbols, nil when unset; the rest as HostRegistry::HostEntry
  # describes them, nil when unset; models: {downcased id => HostModel}.
  HostConfig = Data.define(:name, :host, :port, :scheme, :url, :transport, :api, :api_key_env, :profile,
                           :first_token_timeout, :vision, :sampling, :thinking, :remote, :window_tokens,
                           :llm_context_strategy, :llm_context_apply, :llm_context_budget_tokens, :models) do
    # Every field but name may be left out: nil, models {}.
    def initialize(**fields)
      super(**members.to_h { |m| [m, nil] }, models: {}, **fields)
    end

    # A hosts: entry as written (YAML, or a worker's SAMAGOTCHI_HOSTS_JSON),
    # or nil when it is disabled (enabled: false) or invalid. An invalid
    # one warns once, naming the entry, the way each reader of a setting
    # does for a bad value (that value is then unset).
    # @param raw_name [String, Symbol]
    # @param raw [Hash] string or symbol keys
    # @return [HostConfig, nil]
    def self.parse(raw_name, raw)
      name = raw_name.to_s.strip
      return nil if name.empty?
      return invalid(name, "must match /[a-z0-9][a-z0-9._-]*/i") unless name.match?(ConfigFile::HOST_NAME_RE)
      return invalid(name, "expected mapping") unless raw.is_a?(Hash)
      return nil if disabled?(raw)

      value = ->(key) { raw.key?(key.to_s) ? raw[key.to_s] : raw[key.to_sym] }
      where = "hosts entry '#{name}'"
      fields = {
        api_key_env: value.call(:api_key_env).to_s.strip.then { |v| v.empty? ? nil : v },
        # Kept as written; ModelProfile.resolve warns about an unknown one.
        profile: value.call(:profile).to_s.strip.downcase.then { |v| v.empty? ? nil : v },
        first_token_timeout: value.call(:first_token_timeout),
        vision: ConfigFile.vision_flag(value.call(:vision), where),
        remote: ConfigFile.bool_flag(value.call(:remote), where, "remote"),
        window_tokens: ConfigFile.window_tokens(value.call(:window_tokens), where),
        sampling: ConfigFile.sampling_map(value.call(:sampling), where),
        thinking: Thinking.level(value.call(:thinking), where),
        llm_context_strategy: LLMContextStrategy.parse(value.call(LLMContextStrategy::KEY), where),
        llm_context_apply: LLMContextStrategy.parse_apply(value.call(LLMContextStrategy::APPLY_KEY), where),
        models: HostModel.parse_map(value.call(:models), name),
        llm_context_budget_tokens: LLMContextStrategy.parse_budget(value.call(LLMContextStrategy::BUDGET_KEY), where)
      }
      timeout = fields[:first_token_timeout]
      unless timeout.nil? || (timeout.is_a?(Numeric) && !timeout.negative?)
        ConfigFile.warn_once "Warning: #{where}: first_token_timeout must be seconds (0 = off); using the default"
        fields[:first_token_timeout] = nil
      end
      api_key_env = fields[:api_key_env]
      unless api_key_env.nil? || api_key_env.match?(ConfigFile::ENV_NAME_RE)
        return invalid(name, "api_key_env must be an environment variable name")
      end

      location = parse_location(name, value) or return nil
      kinds = parse_kinds(name, value.call(:transport), value.call(:api)) or return nil
      new(name: name.downcase, **location, **kinds, **fields)
    rescue StandardError => e
      # One entry that trips a reader is dropped on its own, and said so;
      # the other hosts stay (the worker's copy too).
      invalid(name || raw_name, "#{e.class}: #{e.message}")
    end

    # A literal Hash of fields (specs and in-memory callers building a
    # HostRegistry) as a HostConfig, unchecked; a HostConfig as it is.
    # @param name [String] the entry's name
    # @param cfg [HostConfig, Hash] symbol keys, as #to_h gives them
    def self.coerce(name, cfg)
      return cfg if cfg.is_a?(HostConfig)

      new(**cfg.to_h.slice(*members), name: name.to_s.downcase)
    end

    # enabled: false (or "false", any case) in a hosts entry as written.
    def self.disabled?(raw)
      enabled = if raw.key?("enabled")
                  raw["enabled"]
                else
                  (raw.key?(:enabled) ? raw[:enabled] : true)
                end
      enabled == false || enabled.to_s.strip.downcase == "false"
    end

    # host/port/scheme/url from url:, or from host: and port:; nil (warned)
    # when they are wrong.
    def self.parse_location(name, value)
      host = value.call(:host)
      port = value.call(:port)
      url = value.call(:url).to_s.strip
      scheme = "http"
      unless url.empty?
        return invalid(name, "give url or host/port, not both") unless host.to_s.strip.empty? && port.to_s.strip.empty?

        uri = begin
          URI.parse(url)
        rescue URI::InvalidURIError
          nil
        end
        return invalid(name, "url must be an http(s) URL") unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?

        host = uri.host
        port = uri.port
        scheme = uri.scheme
        url = url.chomp("/")
      end
      host = host.to_s.strip
      return invalid(name, "host is required") if host.empty?

      port = port.to_s.strip.empty? ? 8080 : port.to_i
      return invalid(name, "invalid port") if port <= 0 || port > 65_535

      { host: host, port: port, scheme: scheme, url: url.empty? ? nil : url }
    end
    private_class_method :parse_location

    # transport: and api: as symbols; a raw-prompt api is also the
    # transport. nil (warned) when unknown or contradicting each other.
    def self.parse_kinds(name, transport, api)
      transport = transport.to_s.strip.downcase
      if transport.empty?
        transport = nil
      elsif !ConfigFile::VALID_TRANSPORTS_FOR_CONFIG.include?(transport)
        return invalid(name, "unknown transport '#{transport}'")
      end
      api = api.to_s.strip.downcase
      if api.empty?
        api = nil
      elsif !ConfigFile::VALID_APIS_FOR_CONFIG.include?(api)
        return invalid(name, "unknown api '#{api}'")
      elsif ConfigFile::VALID_TRANSPORTS_FOR_CONFIG.include?(api)
        # A raw-prompt api is the transport; a different transport contradicts it.
        return invalid(name, "api '#{api}' conflicts with transport '#{transport}'") if transport && transport != api

        transport = api
      end
      { transport: transport&.to_sym, api: api&.to_sym }
    end
    private_class_method :parse_kinds

    def self.invalid(name, reason)
      ConfigFile.warn_once "Warning: ignoring hosts entry '#{name}': #{reason}"
      nil
    end
    private_class_method :invalid
  end
end
