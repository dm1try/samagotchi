# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "config"
require_relative "cancellation_controller"
require_relative "llm/http"
require_relative "llm/utf8_scrub"
require_relative "vision_context"
require_relative "vision_support"
require_relative "sampling_settings"

module Samagotchi
  # Thin HTTP client for llama.cpp's native /completion endpoint, or an
  # OpenAI-compatible /v1/completions endpoint (e.g. mlx_lm.server or oMLX).
  # Configured by the server.* settings (Samagotchi::Config):
  #   server.host  (default: localhost)
  #   server.port  (default: 8080; oMLX's default is 8000, set it to match)
  #   server.open_timeout (default: 10 seconds)
  #   server.read_timeout (default: 600 seconds)
  #   server.transport (llama_cpp|mlx|omlx, default: llama_cpp)
  class Client
    # The shared HTTP layer's errors, under their old names.
    RequestCancelled = LLM::RequestCancelled
    RetryExhausted = LLM::RetryExhausted

    # The /props probe runs before a turn's generation, so it gets a short
    # budget and no retry (see #server_props).
    CONTEXT_WINDOW_PROBE_OPEN_TIMEOUT = 1
    CONTEXT_WINDOW_PROBE_READ_TIMEOUT = 2
    # Seconds a probe that got no answer (refused, timed out) is remembered:
    # a down or hung server then costs one probe per window, not one per
    # generation, and a new turn doesn't ask again at once. A request to the
    # host that succeeds drops the remembered failure (see
    # #clear_props_failures!).
    PROPS_FAILURE_TTL = 30

    DEFAULT_TRANSPORT = :llama_cpp
    VALID_TRANSPORTS = %i[llama_cpp mlx omlx].freeze

    # One /props cache per host per process. A host has more than one Client
    # in a run (the registry's, a rebuilt HostRegistry's, the Engines of a
    # TUI and a spec): with a cache each, every one of them asks /props for
    # the same server. Keyed by the host's base URL (scheme://host:port), so
    # two Clients of the same server share the answers their turns read.
    # Entries live for the process: they are the same small hash per host
    # (answers by model, failures by model with their timestamps).
    @props_store = {}
    @props_store_mutex = Mutex.new

    class << self
      # The shared props entry for a host's base URL:
      # { answers: { model => ServerProps }, failures: { model => [props, at] },
      #   mutex: Mutex }. The caller may hold the entry's own mutex.
      def props_entry(base_url)
        @props_store_mutex.synchronize { @props_store[base_url] ||= { answers: {}, failures: {}, mutex: Mutex.new } }
      end

      # Forget every host's answers and failures. Specs call it per example
      # (the store outlives one); nothing in a run does.
      def reset_props_store!
        @props_store_mutex.synchronize { @props_store.clear }
      end
    end

    # Wire-format strategy for one server transport. `Client` keeps the
    # transport-agnostic request/retry/stream loop; everything that differs
    # between llama.cpp's native API and the OpenAI-compatible servers
    # (mlx_lm.server, oMLX) lives here: endpoint paths, payload keys, streamed
    # content parsing, and the request's `model` field semantics.
    class Transport
      attr_reader :name

      # @param name [Symbol] one of Client::VALID_TRANSPORTS
      # @param model_resolver [Proc, nil] client-installed resolver for the
      #   request's `model` field (oMLX resolves against its /v1/models list;
      #   mlx installs one that always returns nil to omit the field); nil
      #   means forward the selector verbatim (llama.cpp default)
      def initialize(name, model_resolver: nil)
        @name = name
        @model_resolver = model_resolver
      end

      def label
        # oMLX gets its own label so its error paths read "omlx ...", not "mlx ...".
        @name == :llama_cpp ? "llama.cpp" : @name.to_s
      end

      def completion_path
        openai_compatible? ? "/v1/completions" : "/completion"
      end

      def models_path
        openai_compatible? ? "/v1/models" : "/models"
      end

      def token_limit_key
        openai_compatible? ? :max_tokens : :n_predict
      end

      # Where the server describes itself (context window, chat template), or
      # nil when it has no such route. llama.cpp's /props carries the per-slot
      # n_ctx (-c split across --parallel slots) and the chat template.
      # mlx_lm.server and oMLX expose neither.
      def props_path
        openai_compatible? ? nil : "/props"
      end

      def context_window_from(body)
        n_ctx = body.is_a?(Hash) ? body.dig("default_generation_settings", "n_ctx") : nil
        n_ctx.is_a?(Integer) && n_ctx.positive? ? n_ctx : nil
      end

      # Text content carried by one streamed `data:` payload.
      def content_from_payload(payload)
        openai_compatible? ? payload.dig("choices", 0, "text").to_s : payload.fetch("content", "")
      end

      # Why the stream stopped, from its last payload, as an OpenAI finish
      # reason ("length" for the token cap or a full context, "stop"
      # otherwise); nil for a payload that doesn't say. llama.cpp's
      # /completion names it stop_type ("limit", "eos", "word"); the
      # OpenAI-compatible servers send their own finish_reason.
      def finish_reason_from(payload)
        return nil unless payload.is_a?(Hash)
        return payload.dig("choices", 0, "finish_reason") if openai_compatible?

        case payload["stop_type"]
        when "limit" then "length"
        when "eos", "word" then "stop"
        end
      end

      # The request's `model` field for this transport (nil = omit the field):
      #   - llama.cpp: forward the selector (SAMAGOTCHI_DEFAULT_MODEL) verbatim.
      #   - mlx_lm.server: omit `model` entirely (use whatever was loaded via the
      #     server's own `--model` CLI flag).
      #   - oMLX: MUST send a model id that exists in the server's `/v1/models`
      #     list, or oMLX 400s with "model: Field required". The client-installed
      #     resolver maps the short selector (e.g. `gemma-4-26b-a4b-it-4bit`) to
      #     the exact registered id (which may be prefixed, e.g.
      #     `mlx-community--...`) by matching against the loaded /v1/models list.
      def model_for_payload(model)
        return @model_resolver.call(model) if @model_resolver

        value = model.to_s.strip
        value.empty? ? nil : value
      end

      # llama.cpp's own API: slots (`id_slot`), `cache_prompt`, /props.
      def native? = @name == :llama_cpp

      private

      def openai_compatible?
        @name == :mlx || @name == :omlx
      end
    end

    # One /props probe's outcome. `answered?` is false when the probe failed:
    # a network error, a timeout, a turn's cancel or any non-200 (llama.cpp answers 503 while
    # it loads a model). `body` is the parsed JSON of a 200, or nil when it
    # isn't JSON.
    ServerProps = Data.define(:body, :status) do
      def answered?
        status == :ok
      end
    end

    # Moved to its own file; the old name keeps working.
    CancellationController = Samagotchi::CancellationController

    PROBE_CANCEL_KEY = :samagotchi_probe_cancel

    # The cancel a /props probe made on this thread listens to: a turn sets
    # its own (Engine#run_turn), so a Stop cuts the probes it makes before
    # its first request. Probes on other threads (chi self, /model, a
    # status snapshot) have none and run to their timeout.
    def self.probe_cancel = Thread.current[PROBE_CANCEL_KEY]

    # Sets this thread's probe cancel; returns the one it replaces.
    def self.swap_probe_cancel(controller)
      previous = Thread.current[PROBE_CANCEL_KEY]
      Thread.current[PROBE_CANCEL_KEY] = controller
      previous
    end

    # @param sleeper [#call, nil] waits between retries (specs pass a no-op)
    # @param scheme [String, nil] "https" for a TLS server (default http)
    # @param first_token_timeout [Numeric, nil] seconds a completion may take
    #   to stream its first text (LLM::HTTP); nil: no limit
    # @param name [String, nil] the host's config name, for error lines
    #   (default: the transport's label)
    # @param api_key_env [String, nil] the variable holding the host's API
    #   key (llama.cpp's --api-key), sent as a bearer token on every request;
    #   nil sends no Authorization header
    # @param env [Hash] where the key variable is read
    def initialize(host: nil, port: nil, open_timeout: nil, read_timeout: nil, transport: nil, sleeper: nil, scheme: nil,
                   first_token_timeout: nil, name: nil, api_key_env: nil, env: ENV)
      # Unified config precedence: CLI > ENV > file > default (via Samagotchi::Config)
      @host          = host || Samagotchi::Config.get("server.host")
      @port          = (port || Samagotchi::Config.get("server.port")).to_i
      @scheme        = scheme || "http"
      @open_timeout  = Samagotchi::Config.positive_seconds("server.open_timeout", open_timeout)
      @read_timeout  = Samagotchi::Config.positive_seconds("server.read_timeout", read_timeout)
      @transport = build_transport(resolve_transport(transport))
      # This host's process-wide /props entry (see self.props_entry): its
      # answers and failures are shared with every other Client of the same
      # server.
      @props_entry = self.class.props_entry("#{@scheme}://#{@host}:#{@port}")
      @props_cache = @props_entry[:answers]
      @props_failures = @props_entry[:failures]
      @props_mutex = @props_entry[:mutex]
      @first_token_timeout = first_token_timeout
      @host_name = name
      @label = name.to_s.empty? ? @transport.label : name.to_s
      @http = LLM::HTTP.new(label: @label, open_timeout: @open_timeout, read_timeout: @read_timeout,
                            sleeper: sleeper, first_token_timeout: first_token_timeout,
                            api_key: LLM::ApiKey.for(api_key_env, host: @label, env: env))
    end

    # Seconds a completion may take to stream its first text, or nil.
    attr_reader :first_token_timeout

    # The host's config name, or nil when built without one.
    attr_reader :host_name

    # The wire-format strategy for this client's transport.
    attr_reader :transport

    # Send a raw prompt and return the model's completion text.
    #
    # llama.cpp can stream completion chunks as newline-delimited `data: {...}`
    # records. We consume that stream and still return a single joined string so
    # the rest of the harness API stays unchanged.
    #
    # @param prompt      [String]        full formatted prompt string
    # @param stop        [Array<String>] stop sequences
    # @param n_predict   [Integer, nil]  optional max tokens to generate
    # @param model       [String, nil]   optional llama.cpp model identifier
    # @param on_chunk    [Proc, nil]     optional callback per streamed chunk
    # @param cancel_controller [CancellationController, nil] cancellation source for in-flight requests
    # @param on_retry    [Proc, nil]     optional callback before retry sleep
    # @param images      [Array<String>] base64 images, one per
    #   ImagePlan::NATIVE_PLACEHOLDER in the prompt (llama.cpp only)
    # @param sampling    [Hash]          request fields to add (SamplingSettings):
    #   temperature, penalties, …; they can't replace the fields above
    # @param slot        [Integer, nil]  llama.cpp only: the slot (`id_slot`)
    #   this request runs on. PromptWarmup's pin, and only while a warm-up
    #   still runs there: a request pinned to a slot the server has since
    #   cleared skips its prompt cache and prefills everything again
    # @param cache_prompt [Boolean] llama.cpp only: false prefills the whole
    #   prompt, reusing nothing cached (a malformed generation's retry)
    # @return [String] the generated text
    def complete(prompt, stop: [], n_predict: nil, model: nil, on_chunk: nil, cancel_controller: nil, on_retry: nil,
                 images: [], sampling: {}, slot: nil, cache_prompt: true)
      images = Array(images)
      request = { stop: stop, n_predict: n_predict, model: model, sampling: sampling, slot: slot, cache_prompt: cache_prompt }
      return stream_completion(LLM::Utf8Scrub.call(prompt), request, on_chunk, cancel_controller, on_retry) if images.empty?

      # The media marker is random per server process: a restart between the
      # /props read and the request makes the prompt fail to tokenize, so
      # the marker is read again once.
      attempts = 0
      begin
        attempts += 1
        payload_prompt = { prompt_string: LLM::Utf8Scrub.call(prompt.gsub(ImagePlan::NATIVE_PLACEHOLDER, media_marker!(model))),
                           multimodal_data: images }
        stream_completion(payload_prompt, request, on_chunk, cancel_controller, on_retry)
      rescue LLM::BadRequest => e
        raise unless attempts == 1 && e.message.include?("Failed to tokenize prompt")

        invalidate_context_window!
        retry
      end
    end

    OPENAI_API_HINT = "does this host speak the OpenAI API? set `api: openai` on it"

    # What a warm-up (#warm_up) did: the slot it ran on and the server's
    # counts (tokens reused from the cache, tokens prefilled, prefill ms).
    Warmup = Data.define(:slot, :cache_n, :prompt_n, :prompt_ms)

    # Prefill +prompt+ and keep it in the server's cache, so the next
    # request that starts with it only prefills what follows (PromptWarmup:
    # the turn-end warm-up). llama.cpp's native /completion only; nil on
    # any other transport. One non-streamed request generating one token
    # (n_predict 0 does the same on current builds, 1 on every one): no
    # retries, no first-token limit, no stream events. Errors are raised.
    # @param slot [Integer, nil] the slot to run on (`id_slot`): the one the
    #   last request used, which still holds its state
    # @param images [Array<String>] as #complete's
    # @return [Warmup, nil]
    def warm_up(prompt, model: nil, slot: nil, images: [])
      return nil unless @transport.native?

      images = Array(images)
      text = LLM::Utf8Scrub.call(images.empty? ? prompt : prompt.gsub(ImagePlan::NATIVE_PLACEHOLDER, media_marker!(model)))
      payload = { prompt: images.empty? ? text : { prompt_string: text, multimodal_data: images },
                  n_predict: 1, cache_prompt: true, stream: false }
      payload[:id_slot] = slot if slot.is_a?(Integer)
      model_name = @transport.model_for_payload(model)
      payload[:model] = model_name if model_name
      uri = completion_uri
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = payload.to_json
      response = @http.fetch(uri, request, retries: false, log_fields: { model: model, purpose: "warmup" })
      body = JSON.parse(response.body.to_s)
      timings = body["timings"].is_a?(Hash) ? body["timings"] : {}
      Warmup.new(slot: body["id_slot"], cache_n: timings["cache_n"], prompt_n: timings["prompt_n"],
                 prompt_ms: timings["prompt_ms"]&.round)
    end

    # Whether llama.cpp's slot +slot+ is processing a request now (GET
    # /slots, its is_processing): :busy or :idle. nil when unknown: no slot,
    # another transport, the endpoint off (--no-slots), a slot it doesn't
    # list, a bad body or a network error. One quick attempt (PromptWarmup:
    # a warm-up pinned to a busy slot waits behind that request, and the
    # next turn behind the warm-up).
    # @return [Symbol, nil]
    def slot_status(slot, model: nil)
      return nil unless @transport.native? && slot.is_a?(Integer)

      model = model.to_s.strip
      query = model.empty? ? "" : "?#{URI.encode_www_form(model: model)}"
      uri = URI("#{@scheme}://#{@host}:#{@port}/slots#{query}")
      response = @http.fetch(uri, Net::HTTP::Get.new(uri), retries: false, check_status: false,
                                  log_fields: { purpose: "slots" },
                                  open_timeout: CONTEXT_WINDOW_PROBE_OPEN_TIMEOUT,
                                  read_timeout: CONTEXT_WINDOW_PROBE_READ_TIMEOUT)
      return nil unless response.code.to_s == "200"

      entry = Array(JSON.parse(response.body.to_s)).find { |s| s.is_a?(Hash) && s["id"] == slot }
      return nil unless entry&.key?("is_processing")

      entry["is_processing"] == true ? :busy : :idle
    rescue StandardError
      nil
    end

    private def stream_completion(prompt, fields, on_chunk, cancel_controller, on_retry)
      uri = completion_uri
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = completion_payload(prompt, **fields).to_json
      model = fields[:model]

      result = +""
      reset_on_retry = lambda do |event|
        # The retry streams the answer from the start again.
        result = +""
        on_retry&.call(**event)
      end
      @http.stream_lines(uri, request, cancel_controller: cancel_controller, on_retry: reset_on_retry,
                                       on_network_error: ->(_error) { invalidate_context_window! },
                                       log_fields: { model: model, purpose: "chat",
                                                     sampling: SamplingSettings.log_text(sendable_sampling(fields[:sampling])) }) do |line, shown|
        parsed_chunk = parse_stream_line(line)
        next unless parsed_chunk

        content, payload = parsed_chunk
        shown.call unless content.to_s.empty?
        result << content
        next unless on_chunk

        chunk = { content: content, payload: payload }
        finish_reason = @transport.finish_reason_from(payload)
        chunk[:finish_reason] = finish_reason if finish_reason
        on_chunk.call(**chunk)
      end
      # The host answered: a /props probe that failed while it was down (or
      # loading) is no longer true, so the next turn asks it again instead
      # of reusing the failure for the rest of its PROPS_FAILURE_TTL.
      clear_props_failures!
      result
    rescue LLM::BadRequest => e
      raise unless e.status == 404 && @transport.name == :llama_cpp

      # No native /completion here: likely an OpenAI-compatible server.
      raise LLM::BadRequest.new(e.message, host: e.host, status: e.status, attempts: e.attempts, hint: OPENAI_API_HINT)
    rescue RequestCancelled, LLM::ProviderError
      raise
    rescue StandardError => e
      raise "#{@transport.label} request failed (#{@host}:#{@port}): #{e.message}"
    end

    # The running llama.cpp's media marker (/props), or a VisionUnsupported.
    def media_marker!(model)
      marker = @transport.props_path && VisionSupport.media_marker(server_props(model: model))
      return marker if marker

      raise LLM::VisionUnsupported.new("#{@label}: can't reach /props for the media marker", host: @label)
    end

    def list_models
      uri = URI("#{@scheme}://#{@host}:#{@port}#{@transport.models_path}")
      response = @http.fetch(uri, Net::HTTP::Get.new(uri), log_fields: { purpose: "models" })
      clear_props_failures!
      parsed = JSON.parse(response.body.to_s)
      parsed.fetch("data", parsed)
    rescue LLM::ProviderError
      raise
    rescue StandardError => e
      raise "#{@transport.label} model listing failed (#{@host}:#{@port}): #{e.message}"
    end

    # What the running server says about itself (/props), as a ServerProps,
    # or nil when the transport has no such route. One GET with short
    # timeouts and no retry: it runs before generation and must never hold up
    # a turn. The probe names the model (`?model=`): a llama.cpp router
    # answers a stub without it, and a single-model server ignores it.
    # Whatever the server answers (a non-200 too) is cached per model; a
    # network failure for PROPS_FAILURE_TTL seconds, then the next call asks
    # again. A probe cut by this thread's Client.probe_cancel answers
    # :cancelled, uncached, and the turn's next request ends it. A completion
    # or model list this client gets through clears the failures: a server
    # that just answered is not the down or hung one the window remembered.
    def server_props(model: nil)
      path = @transport.props_path
      return nil unless path

      key = model.to_s
      @props_mutex.synchronize do
        return @props_cache[key] if @props_cache.key?(key)

        failed, failed_at = @props_failures[key]
        return failed if failed && monotonic_now - failed_at < PROPS_FAILURE_TTL
      end

      props = probe_props(path, key)
      @props_mutex.synchronize do
        case props.status
        when :cancelled then nil
        when :network_error then @props_failures[key] = [props, monotonic_now]
        else
          @props_cache[key] = props
          @props_failures.delete(key)
        end
      end
      props
    end

    # The /props answer #server_props already has for +model+, or nil;
    # never asks the server.
    def cached_server_props(model: nil)
      @props_mutex.synchronize { @props_cache[model.to_s] }
    end

    # The context window (tokens) the running server was started with, or nil
    # when the transport reports none or the probe fails (see #server_props).
    def context_window(model: nil)
      props = server_props(model: model)
      props&.answered? ? @transport.context_window_from(props.body) : nil
    rescue StandardError
      nil
    end

    # Forget cached /props answers for this host: the server may have
    # restarted with another -c, or a model switch may have loaded one with a
    # different window. The host's entry is shared with every Client of the
    # same server, so the clear reaches them all. A recent failure stays
    # until its PROPS_FAILURE_TTL ends: it holds no stale window, and asking
    # a hung server again at every turn's start is what it saves.
    def invalidate_context_window!
      @props_mutex.synchronize { @props_cache.clear }
    end

    private

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # The host answered a request: whatever a probe failed with (refused,
    # timed out, 503 while it loaded) is stale, so the next probe asks it
    # again rather than serving the failure for the rest of its
    # PROPS_FAILURE_TTL. A cached answer stays: it was read from the same
    # running server.
    def clear_props_failures!
      @props_mutex.synchronize { @props_failures.clear }
    end

    def probe_props(path, model)
      query = model.empty? ? "" : "?#{URI.encode_www_form(model: model)}"
      uri = URI("#{@scheme}://#{@host}:#{@port}#{path}#{query}")
      response = @http.fetch(uri, Net::HTTP::Get.new(uri), retries: false, check_status: false,
                                  log_fields: { model: model.empty? ? nil : model, purpose: "probe" },
                                  open_timeout: CONTEXT_WINDOW_PROBE_OPEN_TIMEOUT,
                                  read_timeout: CONTEXT_WINDOW_PROBE_READ_TIMEOUT,
                                  cancel_controller: Client.probe_cancel)
      return ServerProps.new(body: nil, status: :http_error) unless response.code.to_s == "200"

      ServerProps.new(body: parse_props(response.body), status: :ok)
    rescue RequestCancelled
      ServerProps.new(body: nil, status: :cancelled)
    rescue StandardError
      ServerProps.new(body: nil, status: :network_error)
    end

    def parse_props(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      nil
    end

    def resolve_transport(transport)
      value = (transport || Samagotchi::Config.get("server.transport")).to_s.strip.downcase.to_sym
      VALID_TRANSPORTS.include?(value) ? value : DEFAULT_TRANSPORT
    end

    # Build the wire-format strategy for a resolved transport name. oMLX gets
    # a resolver that maps the short selector to the exact /v1/models id (see
    # #resolve_omlx_model); mlx gets a resolver that always returns nil so the
    # `model` field is omitted; llama.cpp uses the strategy's default (forward
    # the selector verbatim).
    def build_transport(name)
      resolver = case name
                 when :omlx
                   ->(model) { resolve_omlx_model(model) }
                 when :mlx
                   ->(_model) {}
                 end
      Transport.new(name, model_resolver: resolver)
    end

    def completion_uri
      URI("#{@scheme}://#{@host}:#{@port}#{@transport.completion_path}")
    end

    def completion_payload(prompt, stop:, n_predict:, model:, sampling: {}, slot: nil, cache_prompt: true)
      payload = { prompt: prompt, stop: stop, stream: true }
      # A non-positive cap is dropped, which leaves the length to the server
      # (unbounded): 0 here never means "only process the prompt". The
      # turn-end warm-up (#warm_up) sends its own payload for that reason.
      payload[@transport.token_limit_key] = n_predict if n_predict && n_predict.to_i.positive?
      model_name = @transport.model_for_payload(model)
      payload[:model] = model_name if model_name
      if @transport.native?
        # llama.cpp's default today, sent anyway: chi's next turn relies on it.
        # false only for the retry of a malformed generation (KernelLoop),
        # which a poisoned cache must not produce again.
        payload[:cache_prompt] = cache_prompt != false
        payload[:id_slot] = slot if slot.is_a?(Integer)
      end
      sendable_sampling(sampling).merge(payload)
    end

    # The sampling fields that go out: no nil (nothing to drop here: the
    # server's defaults apply) and none of the reserved request fields.
    def sendable_sampling(sampling)
      (sampling || {}).reject { |key, value| value.nil? || ConfigFile::SAMPLING_RESERVED_KEYS.include?(key.to_s) }
    end

    # Resolve a user-facing SAMAGOTCHI_DEFAULT_MODEL selector to the exact id oMLX
    # expects in the request body (an id from its `/v1/models` list).
    #
    # Resolution order: exact (case-insensitive) match first, then the first
    # substring match, else the selector passes through unchanged so oMLX returns
    # its own 404 listing the available models. An empty selector yields nil (no
    # model field). The id list is loaded once per client and memoized, but
    # resolution runs on every completion so a runtime model switch re-resolves.
    def resolve_omlx_model(raw)
      value = raw.to_s.strip
      return nil if value.empty?

      ids = fetch_omlx_model_ids
      return value if ids.empty?

      ids.find { |id| id.casecmp?(value) } ||
        ids.select { |id| id.downcase.include?(value.downcase) }.first ||
        value
    end

    # Load and memoize the list of model ids from oMLX's `/v1/models`.
    #
    # Only memoize on success: a failed `list_models` must leave the cache unset
    # so the next completion retries (a transient blip shouldn't disable
    # resolution for the whole session). On failure we return [] so an unknown
    # selector still passes through raw, letting oMLX return its own 400/404
    # (server decides), as documented in docs/configuration.md.
    def fetch_omlx_model_ids
      return @omlx_model_ids if defined?(@omlx_model_ids)

      begin
        ids = list_models.map { |m| m.is_a?(Hash) ? m["id"] : m }
      rescue StandardError
        return []
      end

      @omlx_model_ids = ids
      ids
    end

    # Returns [content, payload] for a streamed SSE line, or nil to skip
    # (blank lines, non-data lines, and the mlx/oMLX `[DONE]` sentinel).
    # Raises the ProviderError of a server's error event.
    def parse_stream_line(line)
      error = LLM::HTTP.sse_error(line, host: @label)
      raise error if error
      return nil if line.empty? || !line.start_with?("data: ")

      data = line.delete_prefix("data: ")
      return nil if data == "[DONE]"

      payload = begin
        JSON.parse(data)
      rescue JSON::ParserError => e
        raise LLM::ProtocolError.new("#{@label}: malformed stream chunk: #{e.message[0, 200]}", host: @label)
      end
      content = @transport.content_from_payload(payload)
      [content, payload]
    end
  end
end
