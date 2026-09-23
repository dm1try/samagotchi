# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "../config"
require_relative "../version"
require_relative "errors"

module Samagotchi
  module LLM
    # The HTTP plumbing every model client shares: timeouts, TLS for https
    # URLs, a line reader for streamed (SSE) bodies, the retry loop for
    # network errors with cancellable waits, and cancel.
    #
    # Cancel: a CancellationController listener closes the in-flight socket,
    # so the reading thread fails its next read and the error becomes
    # RequestCancelled; no exception is thrown into a thread at an arbitrary
    # point. Before the socket exists (while connecting) or between attempts,
    # the listener falls back to raising RequestCancelled in the requesting
    # thread, as Client did before.
    class HTTP
      RETRY_MAX_ENV = "SAMAGOTCHI_RETRY_MAX"
      RETRY_BASE_DELAY_ENV = "SAMAGOTCHI_RETRY_BASE_DELAY"
      RETRY_MAX_DELAY_ENV = "SAMAGOTCHI_RETRY_MAX_DELAY"
      DEFAULT_RETRY_MAX = 5
      DEFAULT_RETRY_BASE_DELAY = 0.5
      DEFAULT_RETRY_MAX_DELAY = 8.0

      # How often a backoff wait checks for a cancel.
      WAIT_TICK = 0.05
      # A Retry-After longer than this is not waited out: the error goes to
      # the user, who can try again later.
      MAX_RETRY_AFTER = 60.0

      NETWORK_ERRORS = [
        Timeout::Error, EOFError, SocketError, IO::TimeoutError,
        Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT
      ].freeze

      # Exponential backoff: base_delay * 2^(attempt-1), capped at max_delay,
      # for up to +max+ retries (max + 1 attempts).
      RetryPolicy = Data.define(:max, :base_delay, :max_delay) do
        # retry.* from config, then the SAMAGOTCHI_RETRY_* env, then defaults.
        def self.from_config
          new(
            max: config_value("retry.max") { |v| v.is_a?(Integer) && v >= 0 } ||
              env_integer(RETRY_MAX_ENV, DEFAULT_RETRY_MAX),
            base_delay: config_value("retry.base_delay") { |v| v.is_a?(Numeric) && v.positive? }&.to_f ||
              env_float(RETRY_BASE_DELAY_ENV, DEFAULT_RETRY_BASE_DELAY),
            max_delay: config_value("retry.max_delay") { |v| v.is_a?(Numeric) && v.positive? }&.to_f ||
              env_float(RETRY_MAX_DELAY_ENV, DEFAULT_RETRY_MAX_DELAY)
          )
        end

        def self.none = new(max: 0, base_delay: DEFAULT_RETRY_BASE_DELAY, max_delay: DEFAULT_RETRY_MAX_DELAY)

        def self.config_value(key)
          value = Samagotchi::Config.get(key)
          yield(value) ? value : nil
        rescue StandardError
          nil
        end

        def self.env_integer(name, default)
          value = ENV.fetch(name, default.to_s).to_i
          value.negative? ? default : value
        end

        def self.env_float(name, default)
          value = ENV.fetch(name, default.to_s).to_f
          value.positive? ? value : default
        end

        # Seconds to wait before retrying after failed attempt +attempt+
        # (1-based), or nil when the budget is spent.
        def delay_for(attempt)
          return nil if attempt > max

          [base_delay * (2**(attempt - 1)), max_delay].min
        end
      end

      def self.network_error?(error)
        NETWORK_ERRORS.any? { |klass| error.is_a?(klass) }
      end

      # The ProviderError an SSE line carries (llama.cpp's `error:` event, a
      # `data:` line with an `error` object), or nil.
      def self.sse_error(line, host:)
        ProviderErrors.from_sse_line(line, host: host)
      end

      attr_reader :label, :retry_policy

      # @param label [String] names the server in RetryExhausted messages
      # @param sleeper [#call] waits the given seconds (specs pass a no-op)
      def initialize(label:, open_timeout:, read_timeout:, retry_policy: nil, sleeper: nil)
        @label = label
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @retry_policy = retry_policy || RetryPolicy.from_config
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      end

      # Send +request+ and yield each line of the streamed body (stripped,
      # blank lines included) as it arrives, with a +shown+ proc. An error
      # status raises its ProviderError. Network errors and retryable errors
      # (a status, or a ProviderError the block raises for an error line)
      # retry the request per the retry policy (a Retry-After wins over the
      # backoff), unless the block called +shown+: it passed something on
      # (text, a tool call), and a retry would repeat it. Lines it only
      # skipped (SSE comments, a role-only chunk, an error event) don't count,
      # so an upstream failure a provider sends as the first event of a 200
      # is retried like the same failure as a status. Any other error is
      # raised as is.
      #
      # @param on_retry [Proc, nil] called before each backoff wait with
      #   attempt:, max_retries:, next_delay:, error_class:, error_message:
      # @param on_network_error [Proc, nil] called with each network error
      # @raise [RequestCancelled] when +cancel_controller+ cancels
      # @raise [RetryExhausted] when the retries run out
      # @raise [ProviderError] for an error status
      def stream_lines(uri, request, cancel_controller: nil, on_retry: nil, on_network_error: nil, &on_line)
        identify(request)
        with_retries(cancel_controller, on_retry, on_network_error) do |current|
          shown = -> { current[:streamed] = true }
          start(uri) do |http|
            current[:http] = http
            http.request(request) do |response|
              check_status!(response)
              buffer = +""
              response.read_body do |chunk|
                buffer << chunk
                while (newline_index = buffer.index("\n"))
                  on_line.call(buffer.slice!(0, newline_index + 1).strip, shown)
                end
              end
              # A body that doesn't end in a newline still has a last line.
              on_line.call(buffer.strip, shown) unless buffer.strip.empty?
            end
          end
        end
      end

      # Send +request+ and return the response with its body read.
      # @param retries [Boolean] false: one attempt, network errors raised as is
      # @param check_status [Boolean] false: return an error response instead
      #   of raising its ProviderError
      def fetch(uri, request, retries: true, check_status: true, open_timeout: nil, read_timeout: nil,
                cancel_controller: nil)
        identify(request)
        attempt = lambda do |current|
          start(uri, open_timeout: open_timeout, read_timeout: read_timeout) do |http|
            current[:http] = http
            http.request(request).tap { |response| check_status!(response) if check_status }
          end
        end
        return attempt.call({ mutex: Mutex.new }) unless retries

        with_retries(cancel_controller, nil, nil, &attempt)
      end

      private

      def identify(request)
        request["User-Agent"] = Samagotchi::USER_AGENT
      end

      def start(uri, open_timeout: nil, read_timeout: nil, &block)
        options = { open_timeout: open_timeout || @open_timeout, read_timeout: read_timeout || @read_timeout }
        options[:use_ssl] = true if uri.scheme == "https"
        Net::HTTP.start(uri.host, uri.port, **options, &block)
      end

      # Runs the block (one attempt) until it returns, retrying network
      # errors. The block gets a hash to put the attempt's Net::HTTP in, so a
      # cancel can reach its socket.
      def with_retries(cancel_controller, on_retry, on_network_error)
        current = { mutex: Mutex.new }
        requesting_thread = Thread.current
        listener_id = cancel_controller&.on_cancel { |reason| abort_request(current, requesting_thread, reason) }
        raise RequestCancelled.new(cancel_controller.reason) if cancel_controller&.cancelled?

        attempts = 0
        loop do
          attempts += 1
          begin
            return yield(current)
          rescue RequestCancelled
            raise
          rescue ProviderError => e
            raise RequestCancelled.new(cancel_controller.reason) if cancel_controller&.cancelled?

            e.attempts = attempts
            raise if !e.retryable? || current[:streamed]

            delay = e.retry_after || @retry_policy.delay_for(attempts)
            raise if delay.nil? || attempts > @retry_policy.max || delay > MAX_RETRY_AFTER

            retry_after(e, attempts, delay, on_retry, cancel_controller)
          rescue StandardError => e
            raise RequestCancelled.new(cancel_controller.reason) if cancel_controller&.cancelled?
            raise unless self.class.network_error?(e)

            on_network_error&.call(e)
            delay = current[:streamed] ? nil : @retry_policy.delay_for(attempts)
            raise RetryExhausted.new(attempts: attempts, last_error: e, label: @label) if delay.nil?

            retry_after(e, attempts, delay, on_retry, cancel_controller)
          ensure
            current.delete(:http)
          end
        end
      ensure
        # A cancel can call the listener after remove_listener returned (the
        # controller calls listeners outside its lock); :done keeps it from
        # raising into this thread once the request is over.
        current[:mutex].synchronize { current[:done] = true }
        cancel_controller&.remove_listener(listener_id)
      end

      def retry_after(error, attempts, delay, on_retry, cancel_controller)
        on_retry&.call(attempt: attempts, max_retries: @retry_policy.max, next_delay: delay,
                       error_class: error.class.name, error_message: error.message)
        wait(delay, cancel_controller)
      end

      def check_status!(response)
        status = response.code.to_i
        return if status.between?(200, 299)

        raise ProviderErrors.from_response(status: status, body: response.body.to_s, host: @label,
                                           retry_after: response["Retry-After"])
      end

      def abort_request(current, requesting_thread, reason)
        current[:mutex].synchronize do
          next if current[:done]

          io = socket_io(current[:http])
          if io
            io.close
          else
            requesting_thread.raise(RequestCancelled.new(reason))
          end
        end
      rescue IOError
        nil
      end

      # The open socket of a started Net::HTTP (its BufferedIO's io), or nil.
      def socket_io(http)
        return nil unless http.is_a?(Net::HTTP)

        io = http.instance_variable_get(:@socket)&.io
        io && !io.closed? ? io : nil
      end

      def wait(seconds, cancel_controller)
        return if seconds <= 0
        return @sleeper.call(seconds) unless cancel_controller

        remaining = seconds
        while remaining.positive?
          raise RequestCancelled.new(cancel_controller.reason) if cancel_controller.cancelled?

          slice = [remaining, WAIT_TICK].min
          @sleeper.call(slice)
          remaining -= slice
        end
      end
    end
  end
end
