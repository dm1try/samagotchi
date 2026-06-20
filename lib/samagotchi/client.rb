# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Samagotchi
  # Thin HTTP client for the llama.cpp native /completion endpoint.
  # Configure via environment variables:
  #   LLAMA_HOST  (default: localhost)
  #   LLAMA_PORT  (default: 8080)
  #   LLAMA_OPEN_TIMEOUT (default: 10 seconds)
  #   LLAMA_READ_TIMEOUT (default: 600 seconds)
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

      def initialize(attempts:, last_error:)
        @attempts = attempts
        @last_error = last_error
        super("llama.cpp request failed after #{attempts} attempts: #{last_error.class}: #{last_error.message}")
      end
    end

    RETRY_MAX_ENV = "SAMAGOTCHI_RETRY_MAX"
    RETRY_BASE_DELAY_ENV = "SAMAGOTCHI_RETRY_BASE_DELAY"
    RETRY_MAX_DELAY_ENV = "SAMAGOTCHI_RETRY_MAX_DELAY"
    DEFAULT_RETRY_MAX = 5
    DEFAULT_RETRY_BASE_DELAY = 0.5
    DEFAULT_RETRY_MAX_DELAY = 8.0

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

    def initialize(host: nil, port: nil, open_timeout: nil, read_timeout: nil)
      @host = host || ENV.fetch("LLAMA_HOST", "localhost")
      @port = (port || ENV.fetch("LLAMA_PORT", "8080")).to_i
      @open_timeout = (open_timeout || ENV.fetch("LLAMA_OPEN_TIMEOUT", "10")).to_i
      @read_timeout = (read_timeout || ENV.fetch("LLAMA_READ_TIMEOUT", "600")).to_i
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
      uri = URI("http://#{@host}:#{@port}/completion")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      payload = { prompt: prompt, stop: stop, stream: true }
      payload[:n_predict] = n_predict if n_predict && n_predict.to_i.positive?
      model_name = model.to_s.strip
      payload[:model] = model_name unless model_name.empty?
      request.body = payload.to_json

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
                  next if line.empty? || !line.start_with?("data: ")

                  payload = JSON.parse(line.delete_prefix("data: "))
                  content = payload.fetch("content", "")
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
            raise RetryExhausted.new(attempts: attempts, last_error: e)
          end

          raise "llama.cpp request failed (#{@host}:#{@port}): #{e.message}"
        ensure
          cancel_controller&.remove_listener(cancel_listener_id)
        end
      end
    end

    private

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
