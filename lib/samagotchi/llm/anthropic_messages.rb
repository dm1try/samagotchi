# frozen_string_literal: true

require "json"
require "uri"
require_relative "../config"
require_relative "../sampling_settings"
require_relative "../thinking"
require_relative "errors"
require_relative "http"
require_relative "model_listing"
require_relative "openai_chat"
require_relative "prompt_cache"
require_relative "anthropic_assembly"
require_relative "anthropic_wire"

module Samagotchi
  module LLM
    # Anthropic's Messages API (`POST {base}/v1/messages`: Anthropic's own,
    # a gateway, or a local server such as Splash) on our own HTTP layer, for
    # the same chat loop as OpenAIChat: ChatLoop's OpenAI-shaped wire
    # messages are translated here (AnthropicWire), and the answer comes back
    # as a ChatResponse whose provider_content holds the content blocks to
    # send back verbatim (#replays_content?).
    #
    # Nothing here keys on a model id: fields are sent explicitly, read
    # leniently, and a host's 400 for a field it refuses is what changes a
    # request.
    class AnthropicMessages
      include ModelListing

      API_VERSION = "2023-06-01"
      DEFAULT_MODELS_TTL = 60
      MAX_MODEL_PAGES = 20
      # How much of a 200's non-stream body is read as a possible JSON error.
      PLAIN_ERROR_LIMIT = 64 * 1024
      # max_tokens when default.max_tokens is unset and the model list names
      # none (a listed one is capped by it too).
      DEFAULT_MAX_TOKENS = 64_000
      # chi's OpenAI-only request fields: never sent to a Messages host
      # (configured sampling passes as written).
      DROPPED_OPTIONS = %i[reasoning_effort chat_template_kwargs stream_options prompt_cache_key logprobs top_logprobs
                           max_completion_tokens].freeze

      attr_reader :base_url, :host_name, :api_key_env, :models_ttl, :first_token_timeout

      # @param entry [HostRegistry::HostEntry]
      def self.for(entry, **)
        new(base_url: entry.api_base_url, host_name: entry.name, api_key_env: entry.api_key_env, auth: entry.auth,
            remote: entry.remote?, **)
      end

      # @param base_url [String] the API root without /v1 (HostEntry#api_base_url)
      # @param auth [Symbol, nil] the header the key goes in (ApiKey::SCHEMES);
      #   nil: x-api-key
      # The rest as OpenAIChat#initialize takes them.
      def initialize(base_url:, host_name:, api_key_env: nil, auth: nil, stream: true, retries: true, timeout: nil,
                     env: ENV, sleeper: nil, retry_policy: nil, models_ttl: DEFAULT_MODELS_TTL, remote: false,
                     first_token_timeout: nil, purpose: "chat", open_timeout: nil)
        @remote = remote
        @purpose = purpose
        @first_token_timeout = first_token_timeout
        @base_url = base_url.to_s.chomp("/")
        @host_name = host_name.to_s
        @api_key_env = api_key_env
        @stream = stream
        init_model_listing(models_ttl)
        open_timeout, read_timeout = timeouts(timeout, open_timeout)
        policy = retry_policy || (retries ? nil : HTTP::RetryPolicy.none)
        @http = HTTP.new(label: @host_name, open_timeout: open_timeout, read_timeout: read_timeout,
                         retry_policy: policy, sleeper: sleeper, first_token_timeout: first_token_timeout,
                         api_key: ApiKey.for(api_key_env, host: @host_name, env: env, scheme: auth || :x_api_key))
      end

      # The same contract as OpenAIChat#chat; +messages+ are ChatLoop's
      # OpenAI-shaped wire messages.
      # @return [ChatResponse]
      def chat(messages:, model:, tools: [], cancel_controller: nil, on_delta: nil, on_retry: nil, options: {},
               session_id: nil)
        body = request_body(messages, tools, model, options)
        request = post_request("#{@base_url}/v1/messages", body, session_id: session_id)
        log_fields = { model: model, purpose: @purpose, sampling: sampling_summary(body), cache: cache_summary(body) }
        return chat_once(request, cancel_controller, log_fields) unless @stream

        chat_streamed(request, cancel_controller, on_delta, on_retry, log_fields)
      end

      # A provider on the network: no llama.cpp /props to ask for the window.
      def remote? = @remote

      # The response's blocks go back verbatim (ChatLoop#wire_messages
      # copies a model entry's anthropic_content onto its wire message).
      def replays_content? = true

      # true when a streamed event (as #chat's on_delta gets it) carries
      # part of a tool call.
      def tool_call_delta?(payload) = AnthropicAssembly.tool_call_delta?(payload)

      # The request fields a thinking +level+ (Thinking::LEVELS) adds on this
      # wire: default nothing (the provider's own default), off
      # `thinking: disabled`, low/medium/high adaptive thinking shown
      # summarized at that effort.
      # @return [Hash] frozen
      def thinking_fields(level)
        case level
        when :off then { thinking: { type: "disabled" }.freeze }.freeze
        when *Thinking::EFFORTS
          { thinking: { type: "adaptive", display: "summarized" }.freeze, output_config: { effort: level.to_s }.freeze }.freeze
        else {}.freeze
        end
      end

      # The host's models, every page: GET {base}/v1/models with
      # limit=1000 and after_id paging (has_more/last_id). Anthropic's shape
      # (max_input_tokens, max_tokens, capabilities) and the OpenAI shape a
      # gateway or Splash serves here are both read (ModelListing).
      # @return [Array<ModelInfo>]
      def list_models
        models = []
        after = nil
        MAX_MODEL_PAGES.times do
          query = URI.encode_www_form({ limit: 1000, after_id: after }.compact)
          uri = URI("#{@base_url}/v1/models?#{query}")
          body = parse_json(@http.fetch(uri, Net::HTTP::Get.new(uri), log_fields: { purpose: "models" }).body, "model list")
          models.concat(model_entries(body).map { |raw| model_info(raw) })
          break unless body.is_a?(Hash) && body["has_more"] && body["last_id"]

          after = body["last_id"].to_s
        end
        models
      end

      private

      # Anthropic lists the window as max_input_tokens; else the fields an
      # OpenAI-shaped list carries.
      def window_of(raw)
        window = raw["max_input_tokens"]
        window.is_a?(Integer) && window.positive? ? window : super
      end

      def timeouts(timeout, open_limit = nil)
        open_timeout = Samagotchi::Config.positive_seconds("server.open_timeout")
        read_timeout = Samagotchi::Config.positive_seconds("server.read_timeout")
        open_timeout = [open_timeout, open_limit].min if open_limit
        return [open_timeout, read_timeout] unless timeout

        [[open_timeout, timeout].min, timeout]
      end

      # The Messages body: model, max_tokens, the system blocks, the
      # messages, the stream flag, the tools (tool_choice auto with them),
      # then the options as Messages takes them (chi's OpenAI-only fields
      # dropped; a null drops a field).
      def request_body(messages, tools, model, options)
        options = (options || {}).to_h.transform_keys(&:to_sym).except(*DROPPED_OPTIONS)
        translated = AnthropicWire.translate(messages, cache: (PromptCache.control if @purpose == "chat"))
        body = { model: model, max_tokens: options.delete(:max_tokens) || default_max_tokens(model) }
        body[:system] = translated.system unless translated.system.empty?
        body[:messages] = translated.messages
        body[:stream] = @stream
        unless Array(tools).empty?
          body[:tools] = AnthropicWire.tools(tools)
          body[:tool_choice] = { type: "auto" }
        end
        body.merge(options).compact
      end

      # The model list's max_tokens for +model+ (capped), else the cap.
      def default_max_tokens(model)
        listed = listed_model(model)&.raw&.dig("max_tokens")
        listed.is_a?(Integer) && listed.positive? ? [listed, DEFAULT_MAX_TOKENS].min : DEFAULT_MAX_TOKENS
      rescue StandardError
        DEFAULT_MAX_TOKENS
      end

      # The log line's cache= : on for breakpoints with the default TTL, 1h
      # for cache.ttl 1h, nil for none.
      def cache_summary(body)
        controls = [*Array(body[:system]), *Array(body[:messages]).flat_map { |m| Array(m[:content]) }]
                   .filter_map { |block| block.is_a?(Hash) && (block[:cache_control] || block["cache_control"]) }
        return nil if controls.empty?

        controls.any? { |control| control[:ttl] == "1h" } ? "1h" : "on"
      end

      def sampling_summary(body)
        SamplingSettings.log_text(body.except(:model, :system, :messages, :stream, :tools, :tool_choice))
      end

      def chat_once(request, cancel_controller, log_fields)
        response = @http.fetch(URI(request.uri.to_s), request, cancel_controller: cancel_controller, log_fields: log_fields)
        body = parse_json(response.body, "chat response")
        error = ProviderErrors.from_error_body(response.body.to_s, host: @host_name)
        raise error if error
        raise ProtocolError.new("#{@host_name}: no content in the Messages response", host: @host_name) unless message?(body)

        AnthropicAssembly.from_message(body).response
      end

      def message?(body) = body.is_a?(Hash) && body["content"].is_a?(Array)

      # The SSE stream: each `data:` event goes through the assembly (the
      # `event:` lines are not needed, so a gateway that drops them works);
      # on_delta gets every event but pings, with its text and reasoning.
      def chat_streamed(request, cancel_controller, on_delta, on_retry, log_fields)
        assembly = AnthropicAssembly.new
        events = 0
        other = +""
        plain = +""
        # A retry streams the answer from the start again.
        restart = lambda do |**event|
          assembly = AnthropicAssembly.new
          plain = +""
          on_retry&.call(**event)
        end
        @http.stream_lines(URI(request.uri.to_s), request, cancel_controller: cancel_controller, on_retry: restart,
                                                           log_fields: log_fields) do |line, shown|
          events += 1 if line.start_with?("data:")
          other << line[0, 200] if !line.start_with?("data:") && other.length < 200
          raise_plain_error(plain, line) if events.zero?
          event = parse_line(line)
          next unless event

          content, reasoning = assembly.add(event)
          shown.call if AnthropicAssembly.shows?(event)
          on_delta&.call(content: content, reasoning: reasoning, payload: assembly.with_usage(event)) unless event["type"] == "ping"
        end
        raise ProtocolError.new("#{@host_name}: the response had no stream events: #{other}", host: @host_name) if events.zero?

        assembly.response
      end

      # A 200 whose body is a plain JSON error instead of a stream: raised
      # from inside the stream (so it is retried by its kind) once the lines
      # so far parse as an error object (OpenAIChat's rule).
      def raise_plain_error(plain, line)
        return if line.empty? || line.start_with?(":") || (plain.empty? && !line.start_with?("{"))
        return if plain.bytesize > PLAIN_ERROR_LIMIT

        plain << line << "\n"
        error = ProviderErrors.from_error_body(plain, host: @host_name)
        raise error if error
      end

      # The parsed event of a `data:` line; nil for `event:` lines, blank
      # lines and comments. An error event raises its ProviderError.
      def parse_line(line)
        error = HTTP.sse_error(line, host: @host_name)
        raise error if error
        return nil unless line.start_with?("data:")

        data = line.delete_prefix("data:").strip
        return nil if data.empty? || data == "[DONE]"

        event = parse_json(data, "stream event")
        event.is_a?(Hash) ? event : nil
      end

      def parse_json(text, what)
        JSON.parse(text.to_s)
      rescue JSON::ParserError => e
        raise ProtocolError.new("#{@host_name}: malformed #{what}: #{e.message[0, 200]}", host: @host_name)
      end

      def post_request(url, body, session_id: nil)
        Net::HTTP::Post.new(URI(url)).tap do |request|
          request["Content-Type"] = "application/json"
          request["anthropic-version"] = API_VERSION
          request["Session-Id"] = session_id.to_s unless session_id.to_s.empty?
          request.body = JSON.generate(body)
        end
      end
    end
  end
end
