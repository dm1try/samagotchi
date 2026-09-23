# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "config"
require_relative "cancellation_controller"

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
    class RequestCancelled < StandardError
      attr_reader :reason

      def initialize(reason = nil)
        @reason = reason
        super("request cancelled")
      end
    end

    class RetryExhausted < StandardError
      attr_reader :attempts, :last_error

      def initialize(attempts:, last_error:, label: "llama.cpp")
        @attempts = attempts
        @last_error = last_error
        super("#{label} request failed after #{attempts} attempts: #{last_error.class}: #{last_error.message}")
      end
    end

    RETRY_MAX_ENV = "SAMAGOTCHI_RETRY_MAX"
    RETRY_BASE_DELAY_ENV = "SAMAGOTCHI_RETRY_BASE_DELAY"
    RETRY_MAX_DELAY_ENV = "SAMAGOTCHI_RETRY_MAX_DELAY"
    DEFAULT_RETRY_MAX = 5
    DEFAULT_RETRY_BASE_DELAY = 0.5
    DEFAULT_RETRY_MAX_DELAY = 8.0

    # The context-window probe runs before a turn's generation, so it gets a
    # short budget and no retry (see #context_window).
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

      # Where the server reports the context window it was started with, or
      # nil when it reports none. llama.cpp's /props carries the per-slot
      # n_ctx (-c split across --parallel slots). mlx_lm.server and oMLX
      # expose no such field.
      def context_window_path
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

    # Moved to its own file; the old name keeps working.
    CancellationController = Samagotchi::CancellationController

    def initialize(host: nil, port: nil, open_timeout: nil, read_timeout: nil, transport: nil)
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
      @open_timeout  = (open_timeout || cfg_open_timeout).to_i
      @read_timeout  = (read_timeout || cfg_read_timeout).to_i
      transport_fallback = cfg_transport_raw || ENV.fetch(SERVER_TRANSPORT_ENV, DEFAULT_TRANSPORT.to_s)
      @transport = build_transport(resolve_transport(transport || transport_fallback))
      @context_window_cache = {}
      @context_window_mutex = Mutex.new
      @retry_max = begin
        v = Samagotchi::Config.get("retry.max") rescue nil
        v.is_a?(Integer) && v >= 0 ? v : integer_config(RETRY_MAX_ENV, DEFAULT_RETRY_MAX)
      end
      @retry_base_delay = begin
        v = Samagotchi::Config.get("retry.base_delay") rescue nil
        v.is_a?(Numeric) && v.positive? ? v.to_f : float_config(RETRY_BASE_DELAY_ENV, DEFAULT_RETRY_BASE_DELAY)
      end
      @retry_max_delay = begin
        v = Samagotchi::Config.get("retry.max_delay") rescue nil
        v.is_a?(Numeric) && v.positive? ? v.to_f : float_config(RETRY_MAX_DELAY_ENV, DEFAULT_RETRY_MAX_DELAY)
      end
    end

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
    # @return [String] the generated text
    def complete(prompt, stop: ["<end_of_turn>", "<|tool_response>"], n_predict: nil, model: nil, on_chunk: nil, cancel_controller: nil, on_retry: nil)
      uri = completion_uri
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = completion_payload(scrub_utf8(prompt), stop: stop, n_predict: n_predict, model: model).to_json

      attempts = 0

      loop do
        attempts += 1
        result = +""
        buffer = +""
        request_thread = Thread.current
        cancel_listener_id = cancel_controller&.on_cancel do |reason|
          request_thread.raise(RequestCancelled.new(reason))
        end

        if cancel_controller&.cancelled?
          raise RequestCancelled.new(cancel_controller.reason)
        end

        begin
          Net::HTTP.start(
            uri.host,
            uri.port,
            open_timeout: @open_timeout,
            read_timeout: @read_timeout
          ) do |http|
            http.request(request) do |response|
              response.read_body do |chunk|
                buffer << chunk

                while (newline_index = buffer.index("\n"))
                  line = buffer.slice!(0, newline_index + 1).strip
                  parsed_chunk = parse_stream_line(line)
                  next unless parsed_chunk

                  content, payload = parsed_chunk
                  result << content
                  on_chunk&.call(content: content, payload: payload)
                end
              end
            end
          end

          return result
        rescue RequestCancelled
          raise
        rescue StandardError => e
          invalidate_context_window! if retryable_network_error?(e)
          retry_delay = retry_delay_for(attempts)
          if retryable_network_error?(e) && !retry_delay.nil?
            on_retry&.call(
              attempt: attempts,
              max_retries: @retry_max,
              next_delay: retry_delay,
              error_class: e.class.name,
              error_message: e.message
            )
            wait_with_cancellation(retry_delay, cancel_controller)
            next
          end

          if retryable_network_error?(e)
            raise RetryExhausted.new(attempts: attempts, last_error: e, label: @transport.label)
          end

          raise "#{@transport.label} request failed (#{@host}:#{@port}): #{e.message}"
        ensure
          cancel_controller&.remove_listener(cancel_listener_id)
        end
      end
    end

    def list_models
      uri = URI("http://#{@host}:#{@port}#{@transport.models_path}")
      request = Net::HTTP::Get.new(uri)

      attempts = 0

      loop do
        attempts += 1

        begin
          response_body = nil
          Net::HTTP.start(
            uri.host,
            uri.port,
            open_timeout: @open_timeout,
            read_timeout: @read_timeout
          ) do |http|
            response = http.request(request)
            response_body = response.body.to_s
          end

          parsed = JSON.parse(response_body)
          return parsed.fetch("data", parsed)
        rescue StandardError => e
          retry_delay = retry_delay_for(attempts)
          if retryable_network_error?(e) && !retry_delay.nil?
            wait_with_cancellation(retry_delay, nil)
            next
          end

          if retryable_network_error?(e)
            raise RetryExhausted.new(attempts: attempts, last_error: e, label: @transport.label)
          end

          raise "#{@transport.label} model listing failed (#{@host}:#{@port}): #{e.message}"
        end
      end
    end

    # The context window (tokens) the running server was started with, or nil
    # when the transport reports none or the probe fails. One GET with short
    # timeouts and no retry: it runs before generation and must never hold up
    # a turn. Answers (nil included) are cached per model; a failed probe is
    # not, so the next call asks again.
    def context_window(model: nil)
      path = @transport.context_window_path
      return nil unless path

      key = model.to_s
      @context_window_mutex.synchronize do
        return @context_window_cache[key] if @context_window_cache.key?(key)
      end

      tokens = probe_context_window(path)
      @context_window_mutex.synchronize { @context_window_cache[key] = tokens }
    rescue StandardError
      nil
    end

    # Forget cached windows: the server may have restarted with another -c,
    # or a model switch may have loaded one with a different window.
    def invalidate_context_window!
      @context_window_mutex.synchronize { @context_window_cache.clear }
    end

    private

    def probe_context_window(path)
      uri = URI("http://#{@host}:#{@port}#{path}")
      response = Net::HTTP.start(
        uri.host,
        uri.port,
        open_timeout: CONTEXT_WINDOW_PROBE_OPEN_TIMEOUT,
        read_timeout: CONTEXT_WINDOW_PROBE_READ_TIMEOUT
      ) { |http| http.request(Net::HTTP::Get.new(uri)) }
      return nil unless response.code.to_s == "200"

      @transport.context_window_from(JSON.parse(response.body.to_s))
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
      URI("http://#{@host}:#{@port}#{@transport.completion_path}")
    end

    def completion_payload(prompt, stop:, n_predict:, model:)
      payload = { prompt: prompt, stop: stop, stream: true }
      payload[@transport.token_limit_key] = n_predict if n_predict && n_predict.to_i.positive?
      model_name = @transport.model_for_payload(model)
      payload[:model] = model_name if model_name
      payload
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
    def parse_stream_line(line)
      return nil if line.empty? || !line.start_with?("data: ")

      data = line.delete_prefix("data: ")
      return nil if data == "[DONE]"

      payload = JSON.parse(data)
      content = @transport.content_from_payload(payload)
      [content, payload]
    end

    def retryable_network_error?(error)
      return false if error.is_a?(RequestCancelled)

      error.is_a?(Timeout::Error) ||
        error.is_a?(EOFError) ||
        error.is_a?(SocketError) ||
        error.is_a?(Errno::ECONNREFUSED) ||
        error.is_a?(Errno::ECONNRESET) ||
        error.is_a?(Errno::EHOSTUNREACH) ||
        error.is_a?(Errno::ENETUNREACH) ||
        error.is_a?(Errno::ETIMEDOUT) ||
        error.is_a?(IO::TimeoutError)
    end

    def retry_delay_for(attempt)
      return nil if attempt > @retry_max

      raw_delay = @retry_base_delay * (2**(attempt - 1))
      [raw_delay, @retry_max_delay].min
    end

    def wait_with_cancellation(seconds, cancel_controller)
      return if seconds <= 0
      return sleep(seconds) unless cancel_controller

      remaining = seconds
      tick = 0.05
      while remaining.positive?
        raise RequestCancelled.new(cancel_controller.reason) if cancel_controller.cancelled?

        slice = [remaining, tick].min
        sleep(slice)
        remaining -= slice
      end
    end

    def integer_config(name, default)
      value = ENV.fetch(name, default.to_s).to_i
      value.negative? ? default : value
    end

    def float_config(name, default)
      value = ENV.fetch(name, default.to_s).to_f
      value.positive? ? value : default
    end
  end
end
