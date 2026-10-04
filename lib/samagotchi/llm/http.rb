# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "../config"
require_relative "../version"
require_relative "../log"
require_relative "errors"
require_relative "api_key"

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

      # Requests of these purposes are the ones a turn waits on: INFO lines
      # (and ERROR when they fail). Probes and model lists are DEBUG.
      LOGGED_PURPOSES = %w[chat recap].freeze

      # Exponential backoff: base_delay * 2^(attempt-1), capped at max_delay,
      # for up to +max+ retries (max + 1 attempts).
      RetryPolicy = Data.define(:max, :base_delay, :max_delay) do
        # retry.* (Config); a value out of range is the default.
        def self.from_config
          new(
            max: config_value("retry.max") { |v| v.is_a?(Integer) && v >= 0 } || DEFAULT_RETRY_MAX,
            base_delay: config_value("retry.base_delay") { |v| v.is_a?(Numeric) && v.positive? }&.to_f ||
              DEFAULT_RETRY_BASE_DELAY,
            max_delay: config_value("retry.max_delay") { |v| v.is_a?(Numeric) && v.positive? }&.to_f ||
              DEFAULT_RETRY_MAX_DELAY
          )
        end

        def self.none = new(max: 0, base_delay: DEFAULT_RETRY_BASE_DELAY, max_delay: DEFAULT_RETRY_MAX_DELAY)

        def self.config_value(key)
          value = Samagotchi::Config.get(key)
          yield(value) ? value : nil
        rescue StandardError
          nil
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
      # @param first_token_timeout [Numeric, nil] seconds a stream may take to
      #   show something (see #stream_lines); nil: no limit
      # @param api_key [ApiKey, nil] sent on every request; nil: no
      #   Authorization header (a local server)
      def initialize(label:, open_timeout:, read_timeout:, retry_policy: nil, sleeper: nil, first_token_timeout: nil,
                     api_key: nil)
        @label = label
        @api_key = api_key
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @first_token_timeout = first_token_timeout&.positive? ? first_token_timeout : nil
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
      # With a first_token_timeout, an attempt that hasn't called +shown+
      # when the limit passes is closed and raises FirstTokenTimeout, which
      # is not retried. Keep-alive comments don't count: they reset the read
      # timeout, so without this a queued request can wait silently for as
      # long as the provider keeps it open.
      #
      # @param on_retry [Proc, nil] called before each backoff wait with
      #   attempt:, max_retries:, next_delay:, error_class:, error_message:
      # @param on_network_error [Proc, nil] called with each network error
      # @raise [RequestCancelled] when +cancel_controller+ cancels
      # @raise [RetryExhausted] when the retries run out
      # @raise [ProviderError] for an error status
      # @raise [FirstTokenTimeout] when nothing was shown in time
      # @param log_fields [Hash] what the log line says about the request
      #   (model:, purpose: chat/recap/probe/models); never its body
      def stream_lines(uri, request, cancel_controller: nil, on_retry: nil, on_network_error: nil, log_fields: {}, &on_line)
        identify(request)
        current = new_attempt_state(uri, request, log_fields, stream: true)
        logged(current) do
          with_retries(cancel_controller, on_retry, on_network_error, current) do
            stream_attempt(uri, request, current, &on_line)
          end
        end
      end

      def stream_attempt(uri, request, current, &on_line)
        # Time to first token is the answering attempt's, not the retries'.
        current[:attempt_started_at] = monotonic_now
        shown = lambda do
          current[:streamed] = true
          current[:first_shown_at] ||= monotonic_now
        end
        watch_first_token(current) do
          start(uri) do |http|
            current[:http] = http
            http.request(request) do |response|
              current[:status] = response.code.to_i
              check_status!(response)
              buffer = +""
              response.read_body do |chunk|
                buffer << chunk
                while (newline_index = buffer.index("\n"))
                  yield(buffer.slice!(0, newline_index + 1).strip, shown)
                end
              end
              # A body that doesn't end in a newline still has a last line.
              yield(buffer.strip, shown) unless buffer.strip.empty?
            end
          end
        end
      end
      private :stream_attempt

      # Send +request+ and return the response with its body read.
      # @param retries [Boolean] false: one attempt, network errors raised as
      #   is; either way Net::HTTP's own silent retry is off (see #start)
      # @param check_status [Boolean] false: return an error response instead
      #   of raising its ProviderError
      # @raise [RequestCancelled] when +cancel_controller+ cancels (with or
      #   without retries)
      def fetch(uri, request, retries: true, check_status: true, open_timeout: nil, read_timeout: nil,
                cancel_controller: nil, log_fields: {})
        identify(request)
        current = new_attempt_state(uri, request, log_fields, stream: false)
        attempt = lambda do |state|
          start(uri, open_timeout: open_timeout, read_timeout: read_timeout, max_retries: 0) do |http|
            state[:http] = http
            http.request(request).tap do |response|
              state[:status] = response.code.to_i
              check_status!(response) if check_status
            end
          end
        end
        logged(current) do
          next with_retries(cancel_controller, nil, nil, current, &attempt) if retries

          cancellable(cancel_controller, current) do
            attempt.call(current.merge!(attempts: 1))
          rescue StandardError => e
            raise RequestCancelled, cancel_controller.reason if !e.is_a?(RequestCancelled) && cancel_controller&.cancelled?

            raise
          end
        end
      end

      private

      # User-Agent, and the host's key when it has one (AuthError, before
      # any request, when its variable is not set).
      def identify(request)
        request["User-Agent"] = Samagotchi::USER_AGENT
        @api_key&.authorize(request)
      end

      def start(uri, open_timeout: nil, read_timeout: nil, max_retries: nil, &)
        options = { open_timeout: open_timeout || @open_timeout, read_timeout: read_timeout || @read_timeout }
        # Net::HTTP retries an idempotent request once on its own (max_retries
        # defaults to 1) when the connection drops before an answer: chi's
        # RetryPolicy owns retries (and the log line says how many were sent),
        # so every request here gets Net::HTTP's silent one off. Callers may
        # still ask for it explicitly (a fetch whose retries: false passes 0).
        retries = max_retries || 0
        options[:max_retries] = retries
        options[:use_ssl] = true if uri.scheme == "https"
        Net::HTTP.start(uri.host, uri.port, **options, &)
      end

      # Runs the block (one attempt) until it returns, retrying network
      # errors. The block gets a hash to put the attempt's Net::HTTP in, so a
      # cancel can reach its socket.
      def with_retries(cancel_controller, on_retry, on_network_error, current = { mutex: Mutex.new }, &block)
        cancellable(cancel_controller, current) do
          retrying(cancel_controller, on_retry, on_network_error, current, &block)
        end
      end

      # Runs the block with +cancel_controller+ able to abort it: a cancel
      # closes the socket in current[:http] (or raises RequestCancelled in
      # this thread while there is none).
      def cancellable(cancel_controller, current)
        requesting_thread = Thread.current
        listener_id = cancel_controller&.on_cancel { |reason| abort_request(current, requesting_thread, reason) }
        raise RequestCancelled, cancel_controller.reason if cancel_controller&.cancelled?

        yield
      ensure
        # A cancel can call the listener after remove_listener returned (the
        # controller calls listeners outside its lock); :done keeps it from
        # raising into this thread once the request is over.
        current[:mutex].synchronize { current[:done] = true }
        cancel_controller&.remove_listener(listener_id)
      end

      def retrying(cancel_controller, on_retry, on_network_error, current)
        attempts = 0
        loop do
          attempts += 1
          current[:attempts] = attempts
          begin
            return yield(current)
          rescue RequestCancelled
            raise
          rescue ProviderError => e
            raise RequestCancelled, cancel_controller.reason if cancel_controller&.cancelled?

            e.attempts = attempts
            raise if !e.retryable? || current[:streamed]

            delay = e.retry_after || @retry_policy.delay_for(attempts)
            raise if delay.nil? || attempts > @retry_policy.max || delay > MAX_RETRY_AFTER

            retry_after(e, attempts, delay, on_retry, cancel_controller, current)
          rescue StandardError => e
            raise RequestCancelled, cancel_controller.reason if cancel_controller&.cancelled?
            raise first_token_timeout if current[:first_token_expired]
            raise unless self.class.network_error?(e)

            on_network_error&.call(e)
            # Nothing is listening: asking again rarely helps, so it fails
            # at once and says what to check.
            if e.is_a?(Errno::ECONNREFUSED)
              raise ConnectionRefused.new(host: @label, address: current[:address], attempts: attempts)
            end

            delay = current[:streamed] ? nil : @retry_policy.delay_for(attempts)
            raise RetryExhausted.new(attempts: attempts, last_error: e, label: @label) if delay.nil?

            retry_after(e, attempts, delay, on_retry, cancel_controller, current)
          ensure
            current.delete(:http)
          end
        end
      end

      # Runs one attempt (the block) under the first-token limit: a watchdog
      # thread closes the attempt's socket when the limit passes before
      # anything was shown, so the read fails and #with_retries raises
      # FirstTokenTimeout; while still connecting, it raises that in the
      # requesting thread, as a cancel does.
      def watch_first_token(current)
        return yield unless @first_token_timeout

        requesting_thread = Thread.current
        current[:mutex].synchronize { current[:attempt_over] = false }
        watchdog = Thread.new do
          sleep(@first_token_timeout)
          current[:mutex].synchronize do
            next if current[:streamed] || current[:attempt_over] || current[:done]

            current[:first_token_expired] = true
            # No Net::HTTP yet: still connecting. One whose socket is closed
            # has finished, and the attempt returns on its own.
            if current[:http]
              socket_io(current[:http])&.close
            else
              requesting_thread.raise(first_token_timeout)
            end
          end
        rescue IOError
          nil
        end
        yield
      ensure
        if watchdog
          current[:mutex].synchronize { current[:attempt_over] = true }
          watchdog.kill
        end
      end

      def first_token_timeout = FirstTokenTimeout.new(limit: @first_token_timeout, host: @label)

      def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # The per-request state the attempts share (the Net::HTTP a cancel
      # closes, status, timings) and what its log line says.
      def new_attempt_state(uri, request, log_fields, stream:)
        purpose = log_fields[:purpose]&.to_s
        { mutex: Mutex.new, started_at: monotonic_now, stream: stream, address: "#{uri.host}:#{uri.port}",
          level: LOGGED_PURPOSES.include?(purpose) ? :info : :debug,
          log: { host: @label, method: request.method, url: log_url(uri),
                 **log_fields.compact } }
      end

      def log_base(current) = current[:log] || { host: @label }

      # scheme://host[:port]/path: no user info, query or default port.
      def log_url(uri)
        port = uri.port == uri.default_port ? "" : ":#{uri.port}"
        "#{uri.scheme}://#{uri.host}#{port}#{uri.path}"
      end

      # One line per request, whatever its end: done (status, time to the
      # first token of a stream, total), failed, timed out or cancelled.
      # Retries have their own WARN lines (#retry_after).
      def logged(current)
        result = yield
        Log.public_send(current[:level], :http, current[:stream] ? "stream" : "fetch", **log_base(current),
                        status: current[:status], ttft_ms: ttft_ms(current),
                        ms: elapsed_ms(current), attempts: retried(current))
        result
      rescue RequestCancelled => e
        Log.public_send(current[:level], :http, "cancelled", **log_base(current), ms: elapsed_ms(current), reason: e.reason&.to_s)
        raise
      rescue StandardError => e
        failure_level = current[:level] == :info ? :error : :debug
        event = case e
                when FirstTokenTimeout then "first_token_timeout"
                when RetryExhausted then "retry_exhausted"
                else "failed"
                end
        Log.public_send(failure_level, :http, event, **log_base(current), status: e.is_a?(ProviderError) ? e.status : nil,
                                                     ms: elapsed_ms(current), attempts: current[:attempts], error: e.class.name,
                                                     msg: (e.respond_to?(:summary) ? e.summary : e.message).to_s[0, 300])
        raise
      end

      def elapsed_ms(current, at = monotonic_now)
        at && ((at - current[:started_at]) * 1000).round
      end

      def ttft_ms(current)
        shown = current[:first_shown_at]
        shown && ((shown - current[:attempt_started_at]) * 1000).round
      end

      def retried(current)
        current[:attempts].to_i > 1 ? current[:attempts] : nil
      end

      def retry_after(error, attempts, delay, on_retry, cancel_controller, current)
        Log.warn(:http, "retry", **log_base(current), attempt: attempts, max_retries: @retry_policy.max, delay_s: delay,
                                 status: error.is_a?(ProviderError) ? error.status : nil, error: error.class.name,
                                 msg: error.message.to_s[0, 300])
        on_retry&.call(attempt: attempts, max_retries: @retry_policy.max, next_delay: delay,
                       error_class: error.class.name, error_message: error.message,
                       status: error.is_a?(ProviderError) ? error.status : nil)
        wait(delay, cancel_controller)
      end

      def check_status!(response)
        status = response.code.to_i
        return if status.between?(200, 299)

        error = ProviderErrors.from_response(status: status, body: response.body.to_s, host: @label,
                                             retry_after: response["Retry-After"])
        error.hint ||= @api_key ? @api_key.hint : ApiKey.missing_hint(@label) if error.is_a?(AuthError)
        raise error
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
          raise RequestCancelled, cancel_controller.reason if cancel_controller.cancelled?

          slice = [remaining, WAIT_TICK].min
          @sleeper.call(slice)
          remaining -= slice
        end
      end
    end
  end
end
