# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "config"
require_relative "cancellation_controller"
require_relative "llm/http"
require_relative "vision_context"
require_relative "vision_support"
require_relative "sampling_settings"

module Samagotchi
  # Thin HTTP client for llama.cpp's native /completion endpoint, or an
  # OpenAI-compatible /v1/completions endpoint (e.g. mlx_lm.server or oMLX).
  # Configure via environment variables (see Samagotchi::Config):
  #   SAMAGOTCHI_SERVER_HOST  (default: localhost)
  #   SAMAGOTCHI_SERVER_PORT  (default: 8080; oMLX's default is 8000, set it to match)
  #   SAMAGOTCHI_SERVER_OPEN_TIMEOUT (default: 10 seconds)
  #   SAMAGOTCHI_SERVER_READ_TIMEOUT (default: 600 seconds)
  #   SAMAGOTCHI_SERVER_TRANSPORT (llama_cpp|mlx|omlx, default: llama_cpp)
  class Client
    # The shared HTTP layer's errors, under their old names.
    RequestCancelled = LLM::RequestCancelled
    RetryExhausted = LLM::RetryExhausted

    # The /props probe runs before a turn's generation, so it gets a short
    # budget and no retry (see #server_props).
    CONTEXT_WINDOW_PROBE_OPEN_TIMEOUT = 1
    CONTEXT_WINDOW_PROBE_READ_TIMEOUT = 2

    SERVER_TRANSPORT_ENV = "SAMAGOTCHI_SERVER_TRANSPORT"
    DEFAULT_TRANSPORT = :llama_cpp
    VALID_TRANSPORTS = %i[llama_cpp mlx omlx].freeze

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

      private

      def openai_compatible?
        @name == :mlx || @name == :omlx
      end
    end

    # One /props probe's outcome. `answered?` is false when the probe failed:
    # a network error, a timeout or any non-200 (llama.cpp answers 503 while
    # it loads a model). `body` is the parsed JSON of a 200, or nil when it
    # isn't JSON.
    ServerProps = Data.define(:body, :status) do
      def answered?
        status == :ok
      end
    end

    # Moved to its own file; the old name keeps working.
    CancellationController = Samagotchi::CancellationController

    # @param sleeper [#call, nil] waits between retries (specs pass a no-op)
    # @param scheme [String, nil] "https" for a TLS server (default http)
    # @param first_token_timeout [Numeric, nil] seconds a completion may take
    #   to stream its first text (LLM::HTTP); nil: no limit
    # @param name [String, nil] the host's config name, for error lines
    #   (default: the transport's label)
    def initialize(host: nil, port: nil, open_timeout: nil, read_timeout: nil, transport: nil, sleeper: nil, scheme: nil,
                   first_token_timeout: nil, name: nil)
      # Unified config precedence: CLI > ENV > file > default (via Samagotchi::Config)
      cfg_host = nil; cfg_port = nil; cfg_transport_raw = nil
      begin
        cfg_host       = Samagotchi::Config.get("server.host")
        cfg_port       = Samagotchi::Config.get("server.port")
        cfg_open_timeout = Samagotchi::Config.get("server.open_timeout")
        cfg_read_timeout = Samagotchi::Config.get("server.read_timeout")
        cfg_transport_raw = Samagotchi::Config.get("server.transport")
      rescue StandardError
        nil
      end
      @host          = host || cfg_host
      @port          = (port || cfg_port).to_i
      @scheme        = scheme || "http"
      @open_timeout  = (open_timeout || cfg_open_timeout).to_i
      @read_timeout  = (read_timeout || cfg_read_timeout).to_i
      transport_fallback = cfg_transport_raw || ENV.fetch(SERVER_TRANSPORT_ENV, DEFAULT_TRANSPORT.to_s)
      @transport = build_transport(resolve_transport(transport || transport_fallback))
      @props_cache = {}
      @props_mutex = Mutex.new
      @first_token_timeout = first_token_timeout
      @host_name = name
      @label = name.to_s.empty? ? @transport.label : name.to_s
      @http = LLM::HTTP.new(label: @label, open_timeout: @open_timeout, read_timeout: @read_timeout,
                            sleeper: sleeper, first_token_timeout: first_token_timeout)
    end

    # Seconds a completion may take to stream its first text, or nil.
    attr_reader :first_token_timeout

    # The host's config name, or nil when built without one.
    attr_reader :host_name

    # The wire-format strategy for this client's transport.
    def transport
      @transport
    end

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
    # @return [String] the generated text
    def complete(prompt, stop: ["<end_of_turn>", "<|tool_response>"], n_predict: nil, model: nil, on_chunk: nil, cancel_controller: nil, on_retry: nil,
                 images: [], sampling: {})
      images = Array(images)
      request = { stop: stop, n_predict: n_predict, model: model, sampling: sampling }
      return stream_completion(scrub_utf8(prompt), request, on_chunk, cancel_controller, on_retry) if images.empty?

      # The media marker is random per server process: a restart between the
      # /props read and the request makes the prompt fail to tokenize, so
      # the marker is read again once.
      attempts = 0
      begin
        attempts += 1
        payload_prompt = { prompt_string: scrub_utf8(prompt.gsub(ImagePlan::NATIVE_PLACEHOLDER, media_marker!(model))),
                           multimodal_data: images }
        stream_completion(payload_prompt, request, on_chunk, cancel_controller, on_retry)
      rescue LLM::BadRequest => e
        raise unless attempts == 1 && e.message.include?("Failed to tokenize prompt")

        invalidate_context_window!
        retry
      end
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
        on_chunk&.call(content: content, payload: payload)
      end
      result
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
    # network failure is not, so the next call asks again.
    def server_props(model: nil)
      path = @transport.props_path
      return nil unless path

      key = model.to_s
      @props_mutex.synchronize do
        return @props_cache[key] if @props_cache.key?(key)
      end

      props = probe_props(path, key)
      @props_mutex.synchronize { @props_cache[key] = props } unless props.status == :network_error
      props
    end

    # The context window (tokens) the running server was started with, or nil
    # when the transport reports none or the probe fails (see #server_props).
    def context_window(model: nil)
      props = server_props(model: model)
      props&.answered? ? @transport.context_window_from(props.body) : nil
    rescue StandardError
      nil
    end

    # Forget cached /props answers: the server may have restarted with
    # another -c, or a model switch may have loaded one with a different
    # window.
    def invalidate_context_window!
      @props_mutex.synchronize { @props_cache.clear }
    end

    private

    def probe_props(path, model)
      query = model.empty? ? "" : "?#{URI.encode_www_form(model: model)}"
      uri = URI("#{@scheme}://#{@host}:#{@port}#{path}#{query}")
      response = @http.fetch(uri, Net::HTTP::Get.new(uri), retries: false, check_status: false,
                                  log_fields: { model: model.empty? ? nil : model, purpose: "probe" },
                                  open_timeout: CONTEXT_WINDOW_PROBE_OPEN_TIMEOUT,
                                  read_timeout: CONTEXT_WINDOW_PROBE_READ_TIMEOUT)
      return ServerProps.new(body: nil, status: :http_error) unless response.code.to_s == "200"

      ServerProps.new(body: parse_props(response.body), status: :ok)
    rescue StandardError
      ServerProps.new(body: nil, status: :network_error)
    end

    def parse_props(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      nil
    end

    def resolve_transport(transport)
      value = (transport || ENV.fetch(SERVER_TRANSPORT_ENV, DEFAULT_TRANSPORT.to_s)).to_s.strip.downcase.to_sym
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
                   ->(_model) { nil }
                 end
      Transport.new(name, model_resolver: resolver)
    end

    def completion_uri
      URI("#{@scheme}://#{@host}:#{@port}#{@transport.completion_path}")
    end

    def completion_payload(prompt, stop:, n_predict:, model:, sampling: {})
      payload = { prompt: prompt, stop: stop, stream: true }
      payload[@transport.token_limit_key] = n_predict if n_predict && n_predict.to_i.positive?
      model_name = @transport.model_for_payload(model)
      payload[:model] = model_name if model_name
      sendable_sampling(sampling).merge(payload)
    end

    # The sampling fields that go out: no nil (nothing to drop here: the
    # server's defaults apply) and none of the reserved request fields.
    def sendable_sampling(sampling)
      (sampling || {}).reject { |key, value| value.nil? || ConfigFile::SAMPLING_RESERVED_KEYS.include?(key.to_s) }
    end

    # Conversation content (system prompt + tool responses + model output) can
    # contain invalid UTF-8 — e.g. a shell/file op writes a garbled multibyte
    # sequence (a truncated em-dash, a stray replacement byte). `JSON#to_json`
    # raises `JSON::GeneratorError` on such input, which would abort the whole
    # turn. Scrub the payload first: only offending bytes are replaced with "?",
    # every valid UTF-8 string passes through untouched. Non-UTF-8 encodings are
    # left alone because `#to_json` already handles them without raising.
    def scrub_utf8(obj)
      case obj
      when String
        str = obj.to_s
        str.encoding == Encoding::UTF_8 && !str.valid_encoding? ? str.scrub("?") : str
      when Array
        obj.map { |element| scrub_utf8(element) }
      when Hash
        obj.each_with_object({}) { |(key, value), memo| memo[scrub_utf8(key)] = scrub_utf8(value) }
      else
        obj
      end
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
