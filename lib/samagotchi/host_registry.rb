# frozen_string_literal: true

require "ipaddr"
require_relative "config"
require_relative "log"
require_relative "model_ref"
require_relative "client"
require_relative "model_list_store"
require_relative "llm/openai_chat"

module Samagotchi
  # HostRegistry manages multiple model hosts (llama.cpp / mlx / oMLX) and
  # provides lazy model discovery aggregation.
  #
  # - Hosts are defined in config.yml `hosts:` section or synthesized from
  #   SAMAGOTCHI_SERVER_HOST/PORT env (via Config).
  # - Discovery is lazy: list_all_models is the explicit trigger (called by
  #   /models), not on startup. Each host's list is cached (60s, 10 minutes
  #   for a remote host) with skip-on-error; lists are LLM::ModelInfo.
  # - Routing: client_for_model resolves a (possibly qualified) model string
  #   to the appropriate Client instance: host:model, an alias, or an exact
  #   id in a cached list (default host first, then hosts: order); never by
  #   a substring.
  class HostRegistry
    CACHE_TTL_SECONDS = 60
    REMOTE_CACHE_TTL_SECONDS = 600
    # Seconds a remote host's stream may take to show something (a queued
    # free model on OpenRouter can send only keep-alives for minutes).
    REMOTE_FIRST_TOKEN_TIMEOUT = 120

    # url: the configured url, when the entry has one (host, port and scheme
    # come from it); api_key_env: the variable holding the host's API key;
    # profile: the configured prompt profile name, if any;
    # first_token_timeout: the configured first-token limit (see #first_token_limit);
    # vision: the configured true/false (VisionSupport), nil when unset;
    # sampling: the configured request parameters (SamplingSettings), nil when unset;
    # thinking: the configured level (Thinking), nil when unset;
    # remote: the configured true/false (#remote?), nil when unset;
    # window_tokens: the configured context window (ContextWindow.setting), nil when unset.
    HostEntry = Struct.new(:name, :host, :port, :transport, :client, :api, :scheme, :url, :api_key_env, :profile,
                           :first_token_timeout, :vision, :sampling, :thinking, :remote, :window_tokens,
                           keyword_init: true) do
      # Talks the OpenAI chat API (the chat loop); nil and raw apis use the
      # raw-prompt loop.
      def chat? = api == :openai

      # The server root, e.g. for llama.cpp's own endpoints and recap.
      def root_url = "#{scheme || "http"}://#{host}:#{port}"

      # The OpenAI-compatible API base the chat loop talks to: the url as
      # configured, else the root's /v1.
      def openai_base_url = url || "#{root_url}/v1"

      # A provider on the network rather than a local server: hosts.<name>.remote
      # when set, else by its address (HostRegistry.remote_address?). An API
      # key doesn't decide: a llama.cpp on the LAN can have one. A remote
      # host's model list is cached longer, it gets a first-token limit, and
      # it isn't asked for llama.cpp's /props.
      def remote? = remote.nil? ? HostRegistry.remote_address?(scheme, host) : remote

      def models_ttl = remote? ? REMOTE_CACHE_TTL_SECONDS : CACHE_TTL_SECONDS

      # Seconds a streamed answer may take to show something, or nil: the
      # host's first_token_timeout, else server.first_token_timeout, else
      # 120 for a remote host (a local server's long prompt eval is normal,
      # and read_timeout catches a dead one). 0 turns it off.
      def first_token_limit
        seconds = first_token_timeout
        seconds = HostRegistry.configured_first_token_timeout if seconds.nil?
        seconds = remote? ? REMOTE_FIRST_TOKEN_TIMEOUT : nil if seconds.nil?
        seconds&.positive? ? seconds : nil
      end
    end

    # Where a model's requests go: the host entry, the client to use and the
    # model name to send (the host prefix stripped).
    ModelTarget = Data.define(:model, :entry, :bare_model, :client) do
      def root_url = entry.root_url
      def openai_base_url = entry.openai_base_url
    end

    # A client that every target uses instead of its host's own (specs inject
    # a stub this way; the Engine/TUI `client:` keyword sets it).
    attr_accessor :client_override

    # @param clock [#call, nil] monotonic seconds (specs)
    def initialize(hosts_config: nil, env: ENV, client_override: nil, clock: nil)
      @client_override = client_override
      @env = env
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @adapters = {}
      @host_lists = {}
      raw = hosts_config || ConfigFile.hosts_config(env: env)
      @entries = {}
      raw.each do |key, cfg|
        # cfg: {name:, host:, port:, transport:, original_name:}
        transport = cfg[:transport]
        entry = HostEntry.new(name: key.to_s.downcase, host: cfg[:host], port: cfg[:port].to_i, transport: transport,
                              api: cfg[:api]&.to_sym, scheme: cfg[:scheme], url: cfg[:url], api_key_env: cfg[:api_key_env],
                              profile: cfg[:profile], first_token_timeout: cfg[:first_token_timeout],
                              vision: cfg[:vision], sampling: cfg[:sampling], thinking: cfg[:thinking],
                              remote: cfg[:remote], window_tokens: cfg[:window_tokens])
        entry.client = Client.new(host: cfg[:host], port: cfg[:port], transport: transport, scheme: cfg[:scheme],
                                  first_token_timeout: entry.first_token_limit, name: entry.name,
                                  api_key_env: entry.api_key_env, env: env)
        @entries[entry.name] = entry
      end
      # Fallback single entry (should already be synthesized by hosts_config, but guard)
      if @entries.empty?
        host = Config.get("server.host")
        host = "localhost" if host.empty?
        port = Config.get("server.port").to_i
        port = 8080 if port <= 0
        @entries["default"] = HostEntry.new(name: "default", host: host, port: port, transport: nil, client: Client.new(host: host, port: port, name: "default"))
      end
      @mutex = Mutex.new
      @cache = nil
      @cache_at = nil
      @model_index = nil # downcased model_id => [host_name] in hosts: order
    end

    attr_reader :entries

    # Loopback, private (RFC 1918, IPv6 unique local) and link-local nets.
    LOCAL_NETS = %w[127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10
                    ::1/128 fc00::/7 fe80::/10].map { |net| IPAddr.new(net) }.freeze

    # Name suffixes that stay on a home or office network: mDNS, the
    # special-use and customary private names, router defaults (fritz.box)
    # and Tailscale's MagicDNS. Compared on whole labels.
    LOCAL_NAME_SUFFIXES = %w[localhost local lan home home.arpa internal intranet localdomain private corp test
                             box ts.net].freeze

    # Whether an address is remote: https, an http IP address outside the
    # local nets (LOCAL_NETS), or an http name with a dot whose suffix isn't
    # a local one (LOCAL_NAME_SUFFIXES): `gpu.example.com` is remote, while
    # `box`, `mac.local`, `gpu.lan` and `pc.tail1234.ts.net` are local. chi
    # doesn't look names up; hosts.<name>.remote overrides either way.
    def self.remote_address?(scheme, host)
      return true if scheme.to_s == "https"

      address = IPAddr.new(host.to_s.delete_prefix("[").delete_suffix("]"))
      address = address.native if address.ipv4_mapped?
      LOCAL_NETS.none? { |net| net.family == address.family && net.include?(address) }
    rescue IPAddr::Error
      remote_name?(host)
    end

    def self.remote_name?(host)
      name = host.to_s.downcase.delete_suffix(".")
      return false unless name.include?(".")

      LOCAL_NAME_SUFFIXES.none? { |suffix| name == suffix || name.end_with?(".#{suffix}") }
    end
    private_class_method :remote_name?

    # server.first_token_timeout, or nil when unset or unreadable.
    def self.configured_first_token_timeout
      Config.get("server.first_token_timeout")
    rescue StandardError
      nil
    end

    def default_entry
      @entries["default"] || @entries.values.first
    end

    def find_entry(name)
      @entries[name.to_s.strip.downcase]
    end

    # Parse host-qualified model string using known host names.
    # Returns [host_name_or_nil, bare_model]
    def parse_qualified_model(raw)
      ConfigFile.parse_host_qualified_model(raw, hosts: @entries)
    end

    # The names a models: entry may be under, in the order they are looked
    # up: +typed+ as given (maybe an alias), its alias's target, +resolved+
    # (what the model became, e.g. the default for a blank one), the part
    # after a host prefix, and the bare model the host is asked for.
    # Thinking, SamplingSettings, VisionSupport and ModelProfile all take these.
    # @param target [ModelTarget, nil] the resolved model's target (resolved when not given)
    # @return [Array<String>]
    def lookup_names(typed, resolved: nil, target: nil)
      target ||= resolve(resolved || typed)
      [typed, model_ref(typed).ref, resolved, parse_qualified_model(typed).last, target.bare_model]
        .map { |name| name.to_s.strip }.reject(&:empty?).uniq
    end

    # The host a model name, alias or host:model ref goes to and the model
    # id it is sent as (ModelRef: one alias pass). A ref that names a host
    # goes there. A bare id goes to the default host when its cached list
    # has it, else to the first host in hosts: order whose list has it,
    # else to the default host (before /models nothing is listed: no
    # discovery here, the latency budget). Never by a substring.
    def host_for_model(raw_model)
      ref = model_ref(raw_model)
      # ModelRef names a host only when it is one of ours
      return [find_entry(ref.host_name), ref.id] if ref.host_name

      listed = @mutex.synchronize { @model_index }&.fetch(ref.id.to_s.strip.downcase, nil) || []
      default = default_entry
      name = listed.include?(default.name) ? default.name : listed.first
      [(name && find_entry(name)) || default, ref.id]
    end

    # The chat adapter for a host (one per host, so its cached model list
    # serves the context window). Only chat hosts use it for turns.
    # @return [LLM::OpenAIChat]
    def adapter_for(entry)
      @mutex.synchronize do
        @adapters[entry.name] ||= LLM::OpenAIChat.for(entry, models_ttl: entry.models_ttl,
                                                             first_token_timeout: entry.first_token_limit)
      end
    end

    # A host's models as ModelInfo: a chat host's from its adapter, a raw
    # host's from its Client (ids from the server's own list shape).
    def list_models_for(entry)
      return adapter_for(entry).list_models if entry.chat? && !@client_override

      Array(client_for(entry).list_models).map do |raw|
        if raw.is_a?(Hash)
          id = raw["id"] || raw[:id] || raw["model"] || raw["name"]
          LLM::ModelInfo.new(id: id.to_s, context_window: nil, supports_tools: nil, raw: raw)
        else
          LLM::ModelInfo.new(id: raw.to_s, context_window: nil, supports_tools: nil, raw: {})
        end
      end
    end

    def client_for_model(raw_model)
      host_entry, bare = host_for_model(raw_model)
      [client_for(host_entry), bare, host_entry]
    end

    # The single host/model resolution: the alias applied, the host and
    # the name sent to the server (host_for_model).
    # @param raw_model [String] a model name, alias or host:model ref
    # @return [ModelTarget]
    def resolve(raw_model)
      entry, bare = host_for_model(raw_model)
      ModelTarget.new(model: raw_model, entry: entry, bare_model: bare, client: client_for(entry))
    end

    # The model id sent for +full_ref+: its alias applied, a known host
    # prefix stripped ("box:gemma" → "gemma").
    def bare_name(full_ref)
      model_ref(full_ref).id
    end

    # +raw+ parsed against these hosts and config.yml's aliases.
    # @return [ModelRef]
    def model_ref(raw)
      aliases = begin
        ConfigFile.model_aliases(env: @env)
      rescue StandardError
        {}
      end
      ModelRef.parse(raw, hosts: @entries, aliases: aliases)
    end

    def client_for(entry)
      @client_override || entry.client
    end

    # List models on all hosts in parallel. On error per-host, skip with error entry (no failover).
    # Returns { host_name => { host:, port:, transport:, models: [LLM::ModelInfo], error: nil|String } }
    # Also populates the model index. Unless forced, a host's list is reused
    # for its TTL (60s; 10 minutes for a remote host).
    #
    # With +wait+ (seconds), answers by one shared deadline: a host still
    # listing then gets the error "no answer in S s" and its thread is left
    # running (only for a short-lived process: `chi models`). Such a partial
    # listing is not stored as the cache or the model index, so a later
    # resolve doesn't miss the slow host's ids; finished hosts' lists are
    # kept for their TTL as usual.
    def list_all_models(force: true, wait: nil)
      results = {}
      results_mutex = Mutex.new
      threads = @entries.map do |name, entry|
        fresh = !force && fresh_list(name, entry)
        next results_mutex.synchronize { results[name] = fresh } if fresh

        Thread.new do
          begin
            models = list_models_for(entry)
            data = { host: entry.host, port: entry.port, transport: entry.transport, models: models, error: nil }
            @mutex.synchronize { @host_lists[name] = { data: data, at: @clock.call } }
            # On disk too: a process that spawns a worker without listing
            # (`chi send --new --model`, delegate) checks an id against it.
            ModelListStore.save(name, models.map(&:id))
          rescue StandardError => e
            Log.warn(:model, "list_failed", host: name, error: e.class.name, msg: e.message.to_s[0, 500])
            data = { host: entry.host, port: entry.port, transport: entry.transport, models: [], error: e.message }
          end
          results_mutex.synchronize { results[name] = data }
        end
      end
      if wait
        deadline = @clock.call + wait
        threads.each { |thread| thread.join([deadline - @clock.call, 0].max) if thread.is_a?(Thread) }
        partial = false
        # a new hash: the threads keep writing into +results+ (their closure's)
        snapshot = results_mutex.synchronize do
          @entries.each_with_object({}) do |(name, entry), acc|
            acc[name] = results.fetch(name) do
              partial = true
              { host: entry.host, port: entry.port, transport: entry.transport, models: [],
                error: "no answer in #{wait == wait.to_i ? wait.to_i : wait} s" }
            end
          end
        end
        return snapshot if partial
      else
        threads.each { |thread| thread.join if thread.is_a?(Thread) }
      end

      # Model index: model_id downcased -> the hosts listing it, in hosts:
      # order (not the order the threads answered in).
      index = Hash.new { |h, k| h[k] = [] }
      @entries.each_key do |hname|
        data = results[hname]
        next if data.nil? || data[:error]

        Array(data[:models]).each do |m|
          down = m.id.to_s.strip.downcase
          index[down] << hname unless down.empty? || index[down].include?(hname)
        end
      end
      index.default_proc = nil

      @mutex.synchronize do
        @cache = results
        @cache_at = @clock.call
        @model_index = index
      end
      results
    end

    def cached_results
      @mutex.synchronize { @cache }
    end

    private

    def fresh_list(name, entry)
      @mutex.synchronize do
        cached = @host_lists[name]
        cached[:data] if cached && (@clock.call - cached[:at]) < entry.models_ttl
      end
    end
  end
end
