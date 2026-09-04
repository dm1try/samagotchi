# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Samagotchi
  # Thin HTTP client for llama.cpp's native /completion endpoint, or an
  # OpenAI-compatible /v1/completions endpoint (e.g. mlx_lm.server or oMLX).
  # Configure via environment variables:
  #   LLAMA_HOST  (default: localhost)
  #   LLAMA_PORT  (default: 8080; oMLX's default is 8000, set LLAMA_PORT to match)
  #   LLAMA_OPEN_TIMEOUT (default: 10 seconds)
  #   LLAMA_READ_TIMEOUT (default: 600 seconds)
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

    SERVER_TRANSPORT_ENV = "SAMAGOTCHI_SERVER_TRANSPORT"
    DEFAULT_TRANSPORT = :llama_cpp
    VALID_TRANSPORTS = %i[llama_cpp mlx omlx].freeze

    class CancellationController
      def initialize
        @mutex = Mutex.new
        @cancelled = false
        @reason = nil
        @listeners = {}
        @next_listener_id = 0
      end

      def cancel!(reason = :manual)
        listeners = []
        @mutex.synchronize do
          return false if @cancelled

          @cancelled = true
          @reason = reason
          listeners = @listeners.values
          @listeners = {}
        end

        listeners.each do |listener|
          listener.call(reason)
        rescue StandardError
          nil
        end
        true
      end

      def cancelled?
        @mutex.synchronize { @cancelled }
      end

      def reason
        @mutex.synchronize { @reason }
      end

      def on_cancel(&block)
        raise ArgumentError, "block required" unless block

        immediate_reason = nil
        listener_id = nil
        @mutex.synchronize do
          if @cancelled
            immediate_reason = @reason
          else
            listener_id = next_listener_id
            @listeners[listener_id] = block
          end
        end

        if immediate_reason
          block.call(immediate_reason)
          nil
        else
          listener_id
        end
      end

      def remove_listener(listener_id)
        return unless listener_id

        @mutex.synchronize { @listeners.delete(listener_id) }
      end

      private

      def next_listener_id
        @next_listener_id += 1
      end
    end

    def initialize(host: nil, port: nil, open_timeout: nil, read_timeout: nil, transport: nil)
      @host = host || ENV.fetch("LLAMA_HOST", "localhost")
      @port = (port || ENV.fetch("LLAMA_PORT", "8080")).to_i
      @open_timeout = (open_timeout || ENV.fetch("LLAMA_OPEN_TIMEOUT", "10")).to_i
      @read_timeout = (read_timeout || ENV.fetch("LLAMA_READ_TIMEOUT", "600")).to_i
      @transport = resolve_transport(transport)
      @retry_max = integer_config(RETRY_MAX_ENV, DEFAULT_RETRY_MAX)
      @retry_base_delay = float_config(RETRY_BASE_DELAY_ENV, DEFAULT_RETRY_BASE_DELAY)
      @retry_max_delay = float_config(RETRY_MAX_DELAY_ENV, DEFAULT_RETRY_MAX_DELAY)
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
            raise RetryExhausted.new(attempts: attempts, last_error: e, label: transport_label)
          end

          raise "#{transport_label} request failed (#{@host}:#{@port}): #{e.message}"
        ensure
          cancel_controller&.remove_listener(cancel_listener_id)
        end
      end
    end

    def list_models
      uri = URI("http://#{@host}:#{@port}#{models_path}")
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
            raise RetryExhausted.new(attempts: attempts, last_error: e, label: transport_label)
          end

          raise "#{transport_label} model listing failed (#{@host}:#{@port}): #{e.message}"
        end
      end
    end

    private

    def resolve_transport(transport)
      value = (transport || ENV.fetch(SERVER_TRANSPORT_ENV, DEFAULT_TRANSPORT.to_s)).to_s.strip.downcase.to_sym
      VALID_TRANSPORTS.include?(value) ? value : DEFAULT_TRANSPORT
    end

    def transport_label
      # oMLX gets its own label so its error paths read "omlx ...", not "mlx ...".
      @transport == :omlx ? "omlx" : (@transport == :mlx ? "mlx" : "llama.cpp")
    end

    def completion_uri
      path = @transport == :mlx || @transport == :omlx ? "/v1/completions" : "/completion"
      URI("http://#{@host}:#{@port}#{path}")
    end

    def models_path
      @transport == :mlx || @transport == :omlx ? "/v1/models" : "/models"
    end

    def completion_payload(prompt, stop:, n_predict:, model:)
      payload = { prompt: prompt, stop: stop, stream: true }
      token_limit_key = @transport == :mlx || @transport == :omlx ? :max_tokens : :n_predict
      payload[token_limit_key] = n_predict if n_predict && n_predict.to_i.positive?
      model_name = payload_model_name(model)
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

    # Transport semantics for the request's `model` field:
    #   - llama.cpp: forward the selector (SAMAGOTCHI_DEFAULT_MODEL) verbatim.
    #   - mlx_lm.server: omit `model` entirely (use whatever was loaded via the
    #     server's own `--model` CLI flag).
    #   - oMLX: MUST send a model id that exists in the server's `/v1/models`
    #     list, or oMLX 400s with "model: Field required". Our short
    #     SAMAGOTCHI_DEFAULT_MODEL selector (e.g. `gemma-4-26b-a4b-it-4bit`) is resolved
    #     to the exact registered id (which may be prefixed, e.g.
    #     `mlx-community--...`) by matching against the loaded `/v1/models` list.
    def payload_model_name(model)
      case @transport
      when :mlx
        nil
      when :omlx
        resolve_omlx_model(model)
      else
        value = model.to_s.strip
        value.empty? ? nil : value
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
    # (server decides), matching the README's documented behavior.
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
      content = @transport == :mlx || @transport == :omlx ? payload.dig("choices", 0, "text").to_s : payload.fetch("content", "")
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
