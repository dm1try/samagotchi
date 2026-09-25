# frozen_string_literal: true

require_relative "config"
require_relative "client"
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
  #   to the appropriate Client instance. A remote host is chosen only by
  #   exact model id, host:model or an alias, never by a substring.
  class HostRegistry
    CACHE_TTL_SECONDS = 60
    REMOTE_CACHE_TTL_SECONDS = 600
    LIST_TIMEOUT_SECONDS = 3
    # Seconds a remote host's stream may take to show something (a queued
    # free model on OpenRouter can send only keep-alives for minutes).
    REMOTE_FIRST_TOKEN_TIMEOUT = 120

    # url: the configured url, when the entry has one (host, port and scheme
    # come from it); api_key_env: the variable holding the host's API key;
    # profile: the configured prompt profile name, if any;
    # first_token_timeout: the configured first-token limit (see #first_token_limit);
    # vision: the configured true/false (VisionSupport), nil when unset.
    HostEntry = Struct.new(:name, :host, :port, :transport, :client, :api, :scheme, :url, :api_key_env, :profile,
                           :first_token_timeout, :vision, keyword_init: true) do
      # Talks the OpenAI chat API (the chat loop); nil and raw apis use the
      # raw-prompt loop.
      def chat? = api == :openai

      # The server root, e.g. for llama.cpp's own endpoints and recap.
      def root_url = "#{scheme || "http"}://#{host}:#{port}"

      # The OpenAI-compatible API base the chat loop talks to: the url as
      # configured, else the root's /v1.
      def openai_base_url = url || "#{root_url}/v1"

      # A provider on the network rather than a local server: it needs a key
      # or speaks https. Its model list is cached longer and it is never
      # picked by a substring of a model name.
      def remote? = !api_key_env.to_s.empty? || scheme == "https"

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
                              vision: cfg[:vision])
        entry.client = Client.new(host: cfg[:host], port: cfg[:port], transport: transport, scheme: cfg[:scheme],
                                  first_token_timeout: entry.first_token_limit, name: entry.name)
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
      @model_index = nil # downcased model_id => host_name
    end

    def entries
      @entries
    end

    # server.first_token_timeout, or nil when unset or unreadable.
    def self.configured_first_token_timeout
      Config.get("server.first_token_timeout")
    rescue StandardError
      nil
    end

    def entry_names
      @entries.keys
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

    # Resolve model string (already alias-resolved, may be qualified) to a HostEntry.
    # If qualified explicitly, return that host. If unqualified, try cached model index,
    # else fallback to default host.
    def host_for_model(raw_model)
      host_ref, bare = parse_qualified_model(raw_model)
      # If qualified, try to resolve alias on the bare part (recap-box:small -> recap-box:gemma4-small)
      if host_ref && bare
        begin
          aliases = ConfigFile.model_aliases
          resolved = aliases.fetch(bare.downcase, bare)
          bare = resolved if resolved != bare
        rescue StandardError
          nil
        end
        entry = find_entry(host_ref)
        return [entry, bare] if entry
        # Unknown prefix — treat as bare model on default host
        return [default_entry, raw_model.to_s.strip]
      end
      # Unqualified: also try alias resolution for discovery (small -> gemma4-small or small -> recap-box:gemma4-small)
      begin
        aliases = ConfigFile.model_aliases
        resolved = aliases.fetch(bare.to_s.strip.downcase, bare)
        if resolved != bare
          # If alias points to a qualified ref, re-parse it
          q_host, q_bare = parse_qualified_model(resolved)
          if q_host
            entry = find_entry(q_host)
            return [entry, q_bare] if entry
          end
          bare = resolved
        end
      rescue StandardError
        nil
      end
      bare_down = bare.to_s.strip.downcase
      # Try cached index (populated after list_all_models)
      idx = @mutex.synchronize { @model_index }
      if idx && idx.key?(bare_down)
        host_name = idx[bare_down]
        entry = find_entry(host_name)
        return [entry, bare] if entry
      end
      # Fallback: try substring match in cached aggregated results if available
      # (lightweight: scan cached model lists). Remote hosts match exactly only.
      cached = @mutex.synchronize { @cache }
      if cached
        cached.each do |hname, data|
          next unless data[:models]
          data[:models].each do |m|
            if m.id.downcase == bare_down
              entry = find_entry(hname)
              return [entry, bare] if entry
            end
          end
        end
        cached.each do |hname, data|
          next unless data[:models]
          next if find_entry(hname)&.remote?

          data[:models].each do |m|
            if m.id.downcase.include?(bare_down)
              entry = find_entry(hname)
              return [entry, bare] if entry
            end
          end
        end
      end
      [default_entry, bare]
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

    # The single host/model resolution: alias and host routing (host_for_model)
    # plus the name sent to the server (bare_name).
    # @param raw_model [String] a model name, alias or host:model ref
    # @return [ModelTarget]
    def resolve(raw_model)
      entry, = host_for_model(raw_model)
      ModelTarget.new(model: raw_model, entry: entry, bare_model: bare_name(raw_model), client: client_for(entry))
    end

    # The model name without a known host prefix ("box:gemma" → "gemma").
    # Aliases are not applied here.
    def bare_name(full_ref)
      _, bare = parse_qualified_model(full_ref)
      bare.to_s.strip.empty? ? full_ref.to_s.strip : bare
    end

    def client_for(entry)
      @client_override || entry.client
    end

    # List models on all hosts in parallel. On error per-host, skip with error entry (no failover).
    # Returns { host_name => { host:, port:, transport:, models: [LLM::ModelInfo], error: nil|String } }
    # Also populates the model index. Unless forced, a host's list is reused
    # for its TTL (60s; 10 minutes for a remote host).
    def list_all_models(force: true)
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
          rescue StandardError => e
            data = { host: entry.host, port: entry.port, transport: entry.transport, models: [], error: e.message }
          end
          results_mutex.synchronize { results[name] = data }
        end
      end
      threads.each { |thread| thread.join if thread.is_a?(Thread) }

      # Build model index: model_id downcased -> host_name (first host wins)
      index = {}
      results.each do |hname, data|
        next if data[:error]
        Array(data[:models]).each do |m|
          mid = m.id.to_s
          next if mid.strip.empty?
          down = mid.downcase
          index[down] = hname unless index.key?(down)
        end
      end

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
