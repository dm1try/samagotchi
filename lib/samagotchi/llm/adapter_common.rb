# frozen_string_literal: true

require "json"
require "uri"
require_relative "../config"
require_relative "api_key"
require_relative "errors"
require_relative "http"

module Samagotchi
  module LLM
    # What the chat adapters (OpenAIChat, AnthropicMessages) share: the HTTP
    # layer and its timeouts, the paged model list, the SSE line loop with
    # its plain-JSON-error check, and JSON parsing into ProtocolError. The
    # includer sets @host_name and @http (#build_http); the wire itself (the
    # body, the headers, the assembly) stays in each adapter.
    module AdapterCommon
      MAX_MODEL_PAGES = 20
      DEFAULT_MODELS_TTL = 60
      # How much of a 200's non-stream body is read as a possible JSON error.
      PLAIN_ERROR_LIMIT = 64 * 1024

      private

      # The adapter's LLM::HTTP: the timeouts (#timeouts), one attempt when
      # +retries+ is false and no +retry_policy+ is given.
      def build_http(timeout:, open_timeout:, retries:, retry_policy:, sleeper:, first_token_timeout:, api_key:)
        open_timeout, read_timeout = timeouts(timeout, open_timeout)
        policy = retry_policy || (retries ? nil : HTTP::RetryPolicy.none)
        HTTP.new(label: @host_name, open_timeout: open_timeout, read_timeout: read_timeout, retry_policy: policy,
                 sleeper: sleeper, first_token_timeout: first_token_timeout, api_key: api_key)
      end

      # [open, read] seconds: server.open_timeout / server.read_timeout,
      # the open one capped by +open_limit+; a +timeout+ is the read timeout
      # and caps the open one.
      def timeouts(timeout, open_limit = nil)
        open_timeout = Samagotchi::Config.positive_seconds("server.open_timeout")
        read_timeout = Samagotchi::Config.positive_seconds("server.read_timeout")
        open_timeout = [open_timeout, open_limit].min if open_limit
        return [open_timeout, read_timeout] unless timeout

        [[open_timeout, timeout].min, timeout]
      end

      # Every page of the host's model list (MAX_MODEL_PAGES at most): the
      # block gives a page's URI for the last page's last_id (nil first).
      # @return [Array<ModelInfo>]
      def list_model_pages
        models = []
        after = nil
        MAX_MODEL_PAGES.times do
          uri = yield(after)
          body = parse_json(@http.fetch(uri, Net::HTTP::Get.new(uri), log_fields: { purpose: "models" }).body, "model list")
          models.concat(model_entries(body).map { |raw| model_info(raw) })
          break unless body.is_a?(Hash) && body["has_more"] && body["last_id"]

          after = body["last_id"].to_s
        end
        models
      end

      # The streamed answer: each `data:` line's parsed payload goes to the
      # block with the assembly (a fresh +assembly_class+ per attempt: a
      # retry streams the answer from the start again) and the stream's
      # shown callback; the assembly's response at the end. +what+ names a
      # payload in a malformed-JSON error.
      def stream_assembled(request, cancel_controller, on_retry, log_fields, assembly_class:, what:)
        assembly = assembly_class.new
        events = 0
        other = +""
        plain = +""
        restart = lambda do |**event|
          assembly = assembly_class.new
          plain = +""
          on_retry&.call(**event)
        end
        @http.stream_lines(URI(request.uri.to_s), request, cancel_controller: cancel_controller, on_retry: restart,
                                                           log_fields: log_fields) do |line, shown|
          events += 1 if line.start_with?("data:")
          other << line[0, 200] if !line.start_with?("data:") && other.length < 200
          raise_plain_error(plain, line) if events.zero?
          payload = parse_line(line, what)
          next unless payload

          yield assembly, payload, shown
        end
        # A server that ignores stream: true, or answers with something else
        # entirely, would otherwise end the turn with no answer and no error.
        raise ProtocolError.new("#{@host_name}: the response had no stream events: #{other}", host: @host_name) if events.zero?

        assembly.response
      end

      # A 200 whose body is a plain JSON error instead of a stream (OpenRouter
      # sends an upstream 503 so): raised, from inside the stream so it is
      # retried by its kind, once the lines so far parse as an error object.
      def raise_plain_error(plain, line)
        return if line.empty? || line.start_with?(":") || (plain.empty? && !line.start_with?("{"))
        return if plain.bytesize > PLAIN_ERROR_LIMIT

        plain << line << "\n"
        error = ProviderErrors.from_error_body(plain, host: @host_name)
        raise error if error
      end

      # The parsed payload of a `data:` line; nil for `event:` lines, blank
      # lines, comments and [DONE]. An error event raises its ProviderError.
      def parse_line(line, what)
        error = HTTP.sse_error(line, host: @host_name)
        raise error if error
        return nil unless line.start_with?("data:")

        data = line.delete_prefix("data:").strip
        return nil if data.empty? || data == "[DONE]"

        payload = parse_json(data, what)
        payload.is_a?(Hash) ? payload : nil
      end

      def parse_json(text, what)
        JSON.parse(text.to_s)
      rescue JSON::ParserError => e
        raise ProtocolError.new("#{@host_name}: malformed #{what}: #{e.message[0, 200]}", host: @host_name)
      end

      # A JSON POST to +url+: Content-Type, then +headers+ in order, the
      # body generated from +body+.
      def json_post(url, body, headers = {})
        Net::HTTP::Post.new(URI(url)).tap do |request|
          request["Content-Type"] = "application/json"
          headers.each { |name, value| request[name] = value }
          request.body = JSON.generate(body)
        end
      end
    end
  end
end
