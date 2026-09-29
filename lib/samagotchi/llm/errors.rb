# frozen_string_literal: true

require "json"
require "time"

module Samagotchi
  module LLM
    # A request stopped by its CancellationController.
    class RequestCancelled < StandardError
      attr_reader :reason

      def initialize(reason = nil)
        @reason = reason
        super("request cancelled")
      end
    end

    # A model server refused or failed a request. Subclasses name the kind
    # (#kind): the UIs print one line per kind, and #retryable? says whether
    # asking again could help.
    #
    #   ConnectionError  no answer (refused, reset, timeout); RetryExhausted,
    #                    ConnectionRefused
    #   RateLimited      429, with retry_after when the server says
    #   ServerError      5xx or a server's error event mid-stream
    #   AuthError        401/403, or an API key variable that is not set
    #   BadRequest       other 4xx (a context overflow is one, whatever status;
    #                    so is a model that can't take tools)
    #   VisionUnsupported  a model that can't see images (a BadRequest,
    #                    whatever status; also raised before sending)
    #   ProtocolError    a body that isn't what the API promises
    class ProviderError < StandardError
      attr_reader :host, :status, :retry_after
      attr_accessor :attempts

      # @param host [String, nil] the host (or server label) that failed
      # @param status [Integer, nil] the HTTP status, when there was one
      # @param retry_after [Float, nil] seconds the server asked to wait
      def initialize(message = nil, host: nil, status: nil, retryable: nil, retry_after: nil, attempts: 1)
        @host = host
        @status = status
        @retryable = retryable.nil? ? default_retryable? : retryable
        @retry_after = retry_after
        @attempts = attempts
        super(message)
      end

      def retryable? = @retryable

      def kind = :provider

      # One line for the UIs, e.g. "auth failed for host fw: set FW_KEY".
      def summary = "error from host #{host}: #{detail}"

      private

      def default_retryable? = false

      # The message without its leading "host: ".
      def detail
        host && message.start_with?("#{host}: ") ? message.delete_prefix("#{host}: ") : message
      end
    end

    class ConnectionError < ProviderError
      def kind = :connection

      def summary = "can't reach host #{host}: #{detail}"

      private

      def default_retryable? = true
    end

    class RateLimited < ProviderError
      def kind = :rate_limited

      def summary
        "rate limited by host #{host}: #{detail}#{"; retry after #{retry_after.ceil}s" if retry_after}"
      end

      private

      def default_retryable? = true
    end

    class ServerError < ProviderError
      def kind = :server

      def summary = "server error from host #{host}: #{detail}"
    end

    class AuthError < ProviderError
      def kind = :auth

      def summary = "auth failed for host #{host}: #{detail}"
    end

    class BadRequest < ProviderError
      TOOLS_HINT = "this model can't use tools, and chi needs them: pick another model (/model) or host"

      # @param hint [String, nil] what to try, added to the summary
      def initialize(message = nil, context_overflow: false, tools_unsupported: false, hint: nil, **options)
        @context_overflow = context_overflow
        @tools_unsupported = tools_unsupported
        @hint = hint
        super(message, **options)
      end

      attr_reader :hint

      # The prompt is larger than the model's context window.
      def context_overflow? = @context_overflow

      # The model (or every endpoint serving it) refuses requests with tools,
      # and chi always sends them.
      def tools_unsupported? = @tools_unsupported

      def kind = :bad_request

      def summary
        if context_overflow?
          "the conversation is too long for host #{host}'s context window: #{detail}"
        elsif tools_unsupported?
          "host #{host} rejected the request: #{tools_detail}; #{TOOLS_HINT}"
        else
          "host #{host} rejected the request: #{detail}#{"; #{hint}" if hint}"
        end
      end

      private

      # The detail up to the end of the sentence that says the model takes no
      # tools: what a provider adds after it (OpenRouter: "Try disabling
      # "execute"…" and a routing docs link) is advice for its own UI.
      def tools_detail
        text = detail
        match = ProviderErrors::TOOLS_UNSUPPORTED_RE.match(text)
        return text unless match

        stop = text.index(/[.!](\s|\z)/, match.end(0))
        stop ? text[0...stop] : text
      end
    end

    # The model or host can't take images: refused before sending when chi
    # knows it (VisionSupport), or the provider's answer to an image part
    # (OpenRouter 404 "No endpoints found that support image input",
    # llama.cpp 500 "image input is not supported … mmproj"). Never retried.
    class VisionUnsupported < BadRequest
      HINT = "send text only, or pick a model that can see images (/model)"

      def kind = :vision_unsupported

      def summary = "host #{host} can't take images: #{detail}; #{HINT}"

      private

      def default_retryable? = false
    end

    class ProtocolError < ProviderError
      def kind = :protocol

      def summary = "unexpected response from host #{host}: #{detail}"
    end

    # A request that kept failing on network errors until the retry budget
    # ran out (or failed mid-stream, where a retry would repeat output).
    class RetryExhausted < ConnectionError
      attr_reader :last_error

      def initialize(attempts:, last_error:, label: "llama.cpp")
        @last_error = last_error
        super("#{label} request failed after #{attempts} attempts: #{last_error.class}: #{last_error.message}",
              host: label, retryable: false, attempts: attempts)
      end

      def summary = "network error after #{attempts} attempts (host #{host}: #{last_error.class})"
    end

    # A refused connection: nothing listens at the host's address. Not
    # retried (a server that isn't running rarely starts within the backoff).
    class ConnectionRefused < ConnectionError
      attr_reader :address

      def initialize(host:, address: nil, attempts: 1)
        @address = address
        super("#{host}: connection refused#{" at #{address}" if address}", host: host, retryable: false, attempts: attempts)
      end

      def summary = "can't reach host #{host}#{" at #{address}" if address} (connection refused) — is the server running?"
    end

    # A stream that showed nothing (no text, reasoning or tool call) within
    # the host's first-token limit. A queued request can stay open for many
    # minutes on keep-alive comments alone, which reset the read timeout.
    # Not retried: the wait was already long, and a queue would likely
    # queue the retry too.
    class FirstTokenTimeout < ConnectionError
      attr_reader :limit

      def initialize(limit:, host:)
        @limit = limit
        super("#{host}: no answer within #{format_seconds(limit)}s", host: host, retryable: false)
      end

      def kind = :first_token_timeout

      def summary
        "no answer from host #{host} within #{format_seconds(limit)}s (first_token_timeout); " \
          "try again later or pick another model (/model)"
      end

      private

      def format_seconds(seconds) = seconds == seconds.to_i ? seconds.to_i.to_s : seconds.to_s
    end

    # Builds the ProviderError for an HTTP error response or a server's error
    # event.
    module ProviderErrors
      CONTEXT_OVERFLOW_RE = /exceeds? (the )?(available )?context (size|length|window)|context[_ ]length[_ ]exceeded|exceed_context_size|maximum context length/i
      # A model that takes no tools: OpenRouter when no endpoint of the model
      # does ("No endpoints found that support tool use", 404), Ollama ("…
      # does not support tools"), vLLM started without a tool parser.
      TOOLS_UNSUPPORTED_RE = /support tool use|(does not|doesn't) support tools|tool choice requires --enable-auto-tool-choice/i
      # A model or server that can't take images (see VisionUnsupported).
      VISION_UNSUPPORTED_RE = /support image input|image input is not supported|mmproj/i
      RETRYABLE_SERVER_STATUSES = [500, 502, 503, 504, 529].freeze

      module_function

      # @param status [Integer]
      # @param body [String] the response body (JSON or text)
      # @param retry_after [String, nil] the Retry-After header
      def from_response(status:, body:, host:, retry_after: nil)
        message = error_message(body)
        text = "#{host}: HTTP #{status}: #{message}"
        options = { host: host, status: status }
        if CONTEXT_OVERFLOW_RE.match?(message) || CONTEXT_OVERFLOW_RE.match?(body.to_s)
          return BadRequest.new(text, context_overflow: true, **options)
        end
        # Before the status: llama.cpp answers 500, which would be retried.
        return VisionUnsupported.new(text, **options) if VISION_UNSUPPORTED_RE.match?(message)

        case status
        when 401, 403 then AuthError.new(text, **options)
        when 429 then RateLimited.new(text, retry_after: parse_retry_after(retry_after), **options)
        when 408 then ServerError.new(text, retryable: true, **options)
        when 400..499 then BadRequest.new(text, tools_unsupported: TOOLS_UNSUPPORTED_RE.match?(message), **options)
        when 500..599
          ServerError.new(text, retryable: RETRYABLE_SERVER_STATUSES.include?(status),
                                retry_after: parse_retry_after(retry_after), **options)
        else ProtocolError.new(text, **options)
        end
      end

      # The error an SSE line carries, or nil for any other line: llama.cpp's
      # `error: {...}` event, or a `data:` line holding an `error` object.
      def from_sse_line(line, host:)
        if line.start_with?("error:")
          raw = line.delete_prefix("error:").strip
        elsif line.start_with?("data:") && line.include?('"error"')
          raw = line.delete_prefix("data:").strip
          parsed = parse_json(raw)
          return nil unless parsed.is_a?(Hash) && parsed.key?("error")
        else
          return nil
        end

        parsed = parse_json(raw)
        error = parsed.is_a?(Hash) && parsed["error"].is_a?(Hash) ? parsed["error"] : parsed
        code = error.is_a?(Hash) ? error["code"] : nil
        status = code.is_a?(Integer) && code.between?(400, 599) ? code : 500
        from_response(status: status, body: raw, host: host)
      end

      # The human part of an error body: error.message, message, error (a
      # string), or the body itself, shortened. A gateway that passes on an
      # upstream failure (OpenRouter) often says only "Provider returned
      # error" and puts the upstream's words in error.metadata.raw and its
      # name in metadata.provider_name; both are added when present.
      def error_message(body)
        parsed = parse_json(body.to_s)
        message =
          if parsed.is_a?(Hash)
            error = parsed["error"]
            (error.is_a?(Hash) && error["message"]) || (error.is_a?(String) && error) || parsed["message"] || parsed["detail"]
          end
        message = body.to_s if message.nil? || message.to_s.strip.empty?
        message = message.to_s.strip
        message = with_upstream(message, parsed["error"]["metadata"]) if parsed.is_a?(Hash) && parsed["error"].is_a?(Hash)
        message.empty? ? "(empty body)" : message[0, 500]
      end

      # +message+ followed by the upstream provider's name and words from
      # +metadata+ (raw may be text or a JSON error body of its own).
      def with_upstream(message, metadata)
        return message unless metadata.is_a?(Hash)

        provider = metadata["provider_name"].to_s.strip
        raw = metadata["raw"]
        raw = JSON.generate(raw) if raw.is_a?(Hash)
        raw = raw.to_s.strip
        raw = error_message(raw) if raw.start_with?("{")
        message += " (#{provider})" unless provider.empty?
        raw.empty? || message.include?(raw) ? message : "#{message}: #{raw}"
      end

      # Retry-After in seconds (delta-seconds or an HTTP date), or nil.
      def parse_retry_after(value)
        return nil if value.nil? || value.to_s.strip.empty?

        text = value.to_s.strip
        return text.to_f if text.match?(/\A\d+(\.\d+)?\z/)

        seconds = Time.httpdate(text) - Time.now
        seconds.positive? ? seconds : 0.0
      rescue ArgumentError
        nil
      end

      def parse_json(text)
        JSON.parse(text)
      rescue JSON::ParserError
        nil
      end
    end

    # Marks an error that ended a turn with the conversation the loop had
    # built by then (the prompt plus completed tool iterations; a half
    # streamed reply is not kept), so the caller can keep it, as a cancel's
    # salvage does.
    module FailedTurn
      attr_accessor :partial_conversation

      # The innermost loop's conversation wins.
      # @return [Exception] +error+
      def self.attach(error, conversation)
        error.extend(self) unless error.is_a?(self)
        error.partial_conversation ||= conversation
        error
      end
    end
  end
end
