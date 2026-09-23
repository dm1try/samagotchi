# frozen_string_literal: true

require_relative "config"
require_relative "client"

module Samagotchi
  # HostRegistry manages multiple model hosts (llama.cpp / mlx / oMLX) and
  # provides lazy model discovery aggregation.
  #
  # - Hosts are defined in config.yml `hosts:` section or synthesized from
  #   SAMAGOTCHI_SERVER_HOST/PORT env (via Config).
  # - Discovery is lazy: list_all_models is the explicit trigger (called by
  #   /models), not on startup. Results are cached 60s with skip-on-error.
  # - Routing: client_for_model resolves a (possibly qualified) model string
  #   to the appropriate Client instance.
  class HostRegistry
    CACHE_TTL_SECONDS = 60
    LIST_TIMEOUT_SECONDS = 3

    HostEntry = Struct.new(:name, :host, :port, :transport, :client, :api, keyword_init: true) do
      # Talks the OpenAI chat API (the chat loop); nil and raw apis use the
      # raw-prompt loop.
      def chat? = api == :openai

      # The server root, e.g. for llama.cpp's own endpoints and recap.
      def root_url = "http://#{host}:#{port}"

      # The OpenAI-compatible API base the chat loop talks to.
      def openai_base_url = "#{root_url}/v1"
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

    def initialize(hosts_config: nil, env: ENV, client_override: nil)
      @client_override = client_override
      raw = hosts_config || ConfigFile.hosts_config(env: env)
      @entries = {}
      raw.each do |key, cfg|
        # cfg: {name:, host:, port:, transport:, original_name:}
        transport = cfg[:transport]
        client = Client.new(host: cfg[:host], port: cfg[:port], transport: transport)
        entry = HostEntry.new(name: key.to_s.downcase, host: cfg[:host], port: cfg[:port].to_i, transport: transport, client: client,
                              api: cfg[:api]&.to_sym)
        @entries[entry.name] = entry
      end
      # Fallback single entry (should already be synthesized by hosts_config, but guard)
      if @entries.empty?
        host = Config.get("server.host")
        host = "localhost" if host.empty?
        port = Config.get("server.port").to_i
        port = 8080 if port <= 0
        @entries["default"] = HostEntry.new(name: "default", host: host, port: port, transport: nil, client: Client.new(host: host, port: port))
      end
      @mutex = Mutex.new
      @cache = nil
      @cache_at = nil
      @model_index = nil # downcased model_id => host_name
    end

    def entries
      @entries
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
      # (lightweight: scan cached model lists)
      cached = @mutex.synchronize { @cache }
      if cached
        cached.each do |hname, data|
          next unless data[:models]
          data[:models].each do |m|
            mid = (m["id"] || m[:id] || "").to_s
            if mid.downcase == bare_down
              entry = find_entry(hname)
              return [entry, bare] if entry
            end
          end
        end
        cached.each do |hname, data|
          next unless data[:models]
          data[:models].each do |m|
            mid = (m["id"] || m[:id] || "").to_s
            if mid.downcase.include?(bare_down)
              entry = find_entry(hname)
              return [entry, bare] if entry
            end
          end
        end
      end
      [default_entry, bare]
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
    # Returns { host_name => { host:, port:, models: [...], error: nil|String } }
    # Also populates model_index cache (TTL 60s).
    def list_all_models(force: true)
      # Return cached if fresh and not forced
      if !force
        cached = @mutex.synchronize do
          if @cache && @cache_at && (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @cache_at) < CACHE_TTL_SECONDS
            @cache.dup
          end
        end
        return cached if cached
      end

      results = {}
      results_mutex = Mutex.new
      threads = @entries.map do |name, entry|
        Thread.new do
          begin
            # Use a short-lived client timeout for listing to avoid blocking
            # We reuse entry.client but list_models honors retry; for aggregation we want fail-fast per host.
            # So temporarily reduce retry by using a 3s open_timeout-style? Instead just call list_models and rescue RetryExhausted.
            models = client_for(entry).list_models
            models = Array(models)
            results_mutex.synchronize { results[name] = { host: entry.host, port: entry.port, transport: entry.transport, models: models, error: nil } }
          rescue StandardError => e
            results_mutex.synchronize { results[name] = { host: entry.host, port: entry.port, transport: entry.transport, models: [], error: e.message } }
          end
        end
      end
      threads.each(&:join)

      # Build model index: model_id downcased -> host_name (first host wins)
      index = {}
      results.each do |hname, data|
        next if data[:error]
        Array(data[:models]).each do |m|
          mid = (m["id"] || m[:id]).to_s
          next if mid.strip.empty?
          down = mid.downcase
          index[down] = hname unless index.key?(down)
        end
      end

      @mutex.synchronize do
        @cache = results
        @cache_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @model_index = index
      end
      results
    end

    def cached_results
      @mutex.synchronize { @cache }
    end
  end
end
