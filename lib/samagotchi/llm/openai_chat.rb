# frozen_string_literal: true

require "json"
require "uri"
require_relative "../config"
require_relative "../sampling_settings"
require_relative "errors"
require_relative "http"
require_relative "usage"
require_relative "utf8_scrub"

module Samagotchi
  module LLM
    # A model a host lists. Unknown fields are nil.
    ModelInfo = Data.define(:id, :context_window, :supports_tools, :raw) do
      # true when the list says the model takes images (OpenRouter's
      # architecture.input_modalities, llama.cpp's "multimodal" capability),
      # false when it lists input modalities without "image", else nil.
      def image_input
        return nil unless raw.is_a?(Hash)

        modalities = raw.dig("architecture", "input_modalities")
        return modalities.include?("image") if modalities.is_a?(Array)
        return true if Array(raw["capabilities"]).include?("multimodal")

        nil
      end
    end

    # A tool call the model made. arguments: the parsed Hash, or the raw
    # String when it isn't valid JSON (the tool then reports the error).
    ToolCall = Data.define(:id, :name, :arguments)

    # One chat completion: text and reasoning ("" when none), tool calls
    # ([] when none), usage (never nil) and the finish reason.
    # +model+ is the model the server says answered (the body's `model`),
    # which can differ from the one asked for; nil when it says nothing.
    # +cut+ is set on the empty response the chat loop makes for a
    # generation a plugin cut (stop_generation): {by:, reason:}.
    ChatResponse = Data.define(:text, :reasoning, :tool_calls, :usage, :finish_reason, :model, :cut) do
      def initialize(model: nil, cut: nil, **fields) = super
    end

    # The OpenAI Chat Completions API (llama.cpp's /v1, and any compatible
    # provider) on our own HTTP layer: one request per #chat, streamed by
    # default, with errors mapped to ProviderError. It speaks the wire format
    # only; the chat loop owns the conversation and the tools.
    class OpenAIChat
      MAX_MODEL_PAGES = 20
      # How much of a 200's non-stream body is read as a possible JSON error.
      PLAIN_ERROR_LIMIT = 64 * 1024
      DEFAULT_MODELS_TTL = 60

      attr_reader :base_url, :host_name, :api_key_env, :models_ttl, :first_token_timeout

      # @param entry [HostRegistry::HostEntry]
      def self.for(entry, **options)
        new(base_url: entry.openai_base_url, host_name: entry.name, api_key_env: entry.api_key_env,
            remote: entry.remote?, **options)
      end

      # Tool arguments as a Hash; "" is {}, invalid JSON stays a String.
      def self.parse_arguments(raw)
        return raw if raw.is_a?(Hash)

        text = raw.to_s
        return {} if text.strip.empty?

        parsed = JSON.parse(text)
        parsed.is_a?(Hash) ? parsed : text
      rescue JSON::ParserError
        text
      end

      # @param base_url [String] the API base, e.g. http://host:8081/v1
      # @param host_name [String] names the host in errors
      # @param api_key_env [String, nil] the variable holding the API key;
      #   nil sends no Authorization header (a local server)
      # @param stream [Boolean] stream the reply (false: one JSON body)
      # @param retries [Boolean] false: one attempt
      # @param timeout [Numeric, nil] read timeout in seconds (default
      #   server.read_timeout); the connect timeout is capped by it
      # @param models_ttl [Numeric] how long #context_window reuses the list
      # @param remote [Boolean] a provider on the network, not a local server
      # @param first_token_timeout [Numeric, nil] seconds a streamed answer
      #   may take to show something (LLM::HTTP); nil: no limit
      def initialize(base_url:, host_name:, api_key_env: nil, stream: true, retries: true, timeout: nil,
                     env: ENV, sleeper: nil, retry_policy: nil, models_ttl: DEFAULT_MODELS_TTL, remote: false,
                     first_token_timeout: nil, purpose: "chat")
        @remote = remote
        # What its requests are for, in the log (LLM::HTTP::LOGGED_PURPOSES).
        @purpose = purpose
        @first_token_timeout = first_token_timeout
        @base_url = base_url.to_s.chomp("/")
        @host_name = host_name.to_s
        @api_key_env = api_key_env
        @stream = stream
        @models_ttl = models_ttl
        @models_mutex = Mutex.new
        open_timeout, read_timeout = timeouts(timeout)
        policy = retry_policy || (retries ? nil : HTTP::RetryPolicy.none)
        @http = HTTP.new(label: @host_name, open_timeout: open_timeout, read_timeout: read_timeout,
                         retry_policy: policy, sleeper: sleeper, first_token_timeout: first_token_timeout,
                         api_key: ApiKey.for(api_key_env, host: @host_name, env: env))
      end

      # @param messages [Array<Hash>] wire messages (role, content, tool_calls,
      #   tool_call_id); content is a String or an Array of parts
      # @param tools [Array<Hash>] function definitions ({type:, function:})
      # @param options [Hash] extra request fields (max_tokens, ...)
      # @param on_delta [Proc, nil] called per streamed chunk with content:,
      #   reasoning: and payload: (the parsed chunk)
      # @param on_retry [Proc, nil] see LLM::HTTP#stream_lines
      # @param session_id [String, nil] sent as a Session-Id header so a
      #   gateway that spreads requests over providers keeps one
      #   conversation on one of them (prompt caches, one served model)
      # @return [ChatResponse]
      def chat(messages:, model:, tools: [], cancel_controller: nil, on_delta: nil, on_retry: nil, options: {},
               session_id: nil)
        body = request_body(messages, tools, model, options)
        request = post_request("#{@base_url}/chat/completions", body, session_id: session_id)
        log_fields = { model: model, purpose: @purpose, sampling: sampling_summary(body) }
        return chat_once(request, cancel_controller, log_fields) unless @stream

        assembly = Assembly.new
        events = 0
        other = +""
        plain = +""
        # A retry streams the answer from the start again.
        restart = lambda do |**event|
          assembly = Assembly.new
          plain = +""
          on_retry&.call(**event)
        end
        @http.stream_lines(URI(request.uri.to_s), request, cancel_controller: cancel_controller, on_retry: restart,
                                                           log_fields: log_fields) do |line, shown|
          events += 1 if line.start_with?("data:")
          other << line[0, 200] if !line.start_with?("data:") && other.length < 200
          raise_plain_error(plain, line) if events.zero?
          payload = parse_line(line)
          next unless payload

          content, reasoning = assembly.add(payload)
          shown.call if !content.empty? || !reasoning.empty? || Assembly.tool_call_delta?(payload)
          on_delta&.call(content: content, reasoning: reasoning, payload: payload)
        end
        # A server that ignores stream: true, or answers with something else
        # entirely, would otherwise end the turn with no answer and no error.
        raise ProtocolError.new("#{@host_name}: the response had no stream events: #{other}", host: @host_name) if events.zero?

        assembly.response
      end

      # A provider on the network: no llama.cpp /props to ask for the window.
      def remote? = @remote

      # @return [Array<ModelInfo>] the host's models (every page)
      def list_models
        models = []
        after = nil
        MAX_MODEL_PAGES.times do
          uri = URI("#{@base_url}/models#{after ? "?after=#{URI.encode_www_form_component(after)}" : ""}")
          body = parse_json(@http.fetch(uri, get_request(uri), log_fields: { purpose: "models" }).body, "model list")
          models.concat(model_entries(body).map { |raw| model_info(raw) })
          break unless body.is_a?(Hash) && body["has_more"] && body["last_id"]

          after = body["last_id"].to_s
        end
        models
      end

      # The window (tokens) the host lists for +model+, or nil. The list is
      # read once per models_ttl; a failed listing answers nil.
      def context_window(model:)
        info = cached_models.find { |m| m.id == model.to_s } ||
               cached_models.find { |m| m.id.casecmp?(model.to_s) }
        info&.context_window
      rescue StandardError
        nil
      end

      # Whether the host's list says +model+ takes images (ModelInfo#image_input),
      # or nil when it doesn't say or the listing fails.
      def image_input(model:)
        info = cached_models.find { |m| m.id == model.to_s } ||
               cached_models.find { |m| m.id.casecmp?(model.to_s) }
        info&.image_input
      rescue StandardError
        nil
      end

      private

      def timeouts(timeout)
        open_timeout = Samagotchi::Config.positive_seconds("server.open_timeout")
        read_timeout = Samagotchi::Config.positive_seconds("server.read_timeout")
        return [open_timeout, read_timeout] unless timeout

        [[open_timeout, timeout].min, timeout]
      end

      def request_body(messages, tools, model, options)
        body = {
          model: model,
          messages: Array(messages).map { |message| wire_message(message) },
          temperature: 0.0,
          stream: @stream
        }
        body[:stream_options] = { include_usage: true } if @stream
        unless Array(tools).empty?
          body[:tools] = tools
          body[:tool_choice] = "auto"
        end
        # A configured value replaces chi's own (temperature); nil drops it.
        body.merge(options || {}).compact
      end

      # The body's fields beyond the conversation and the stream, for the
      # log line: "temperature=0.6 presence_penalty=1.5".
      def sampling_summary(body)
        SamplingSettings.log_text(body.except(:model, :messages, :stream, :stream_options, :tools, :tool_choice))
      end

      # A String stays a String, an Array of parts an Array; both scrubbed
      # of invalid UTF-8 (Utf8Scrub).
      def wire_message(message)
        wire = message.to_h.transform_keys(&:to_sym)
        wire[:content] = format_content(wire[:content]) if wire.key?(:content)
        wire
      end

      def format_content(content)
        return content if content.nil?

        Utf8Scrub.call(content.is_a?(Array) ? content : content.to_s)
      end

      def chat_once(request, cancel_controller, log_fields)
        response = @http.fetch(URI(request.uri.to_s), request, cancel_controller: cancel_controller, log_fields: log_fields)
        body = parse_json(response.body, "chat response")
        message = body.is_a?(Hash) ? body.dig("choices", 0, "message") : nil
        raise ProtocolError.new("#{@host_name}: no message in the chat response", host: @host_name) unless message.is_a?(Hash)

        calls = Array(message["tool_calls"]).map do |call|
          function = call["function"] || {}
          ToolCall.new(id: call["id"], name: function["name"].to_s, arguments: self.class.parse_arguments(function["arguments"]))
        end
        ChatResponse.new(text: message["content"].to_s,
                         reasoning: (message["reasoning_content"] || message["reasoning"]).to_s,
                         tool_calls: calls, usage: Usage.from_payload(body) || Usage.none,
                         finish_reason: body.dig("choices", 0, "finish_reason"), model: served_model(body))
      end

      def self.served_model(payload)
        model = payload.is_a?(Hash) ? payload["model"] : nil
        model.is_a?(String) && !model.strip.empty? ? model : nil
      end

      def served_model(payload) = self.class.served_model(payload)

      # The parsed payload of a `data:` line; nil for blank lines, comments
      # and [DONE]. Error events raise their ProviderError.
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

      def parse_line(line)
        error = HTTP.sse_error(line, host: @host_name)
        raise error if error
        return nil unless line.start_with?("data:")

        data = line.delete_prefix("data:").strip
        return nil if data.empty? || data == "[DONE]"

        payload = parse_json(data, "stream chunk")
        payload.is_a?(Hash) ? payload : nil
      end

      def parse_json(text, what)
        JSON.parse(text.to_s)
      rescue JSON::ParserError => e
        raise ProtocolError.new("#{@host_name}: malformed #{what}: #{e.message[0, 200]}", host: @host_name)
      end

      def post_request(url, body, session_id: nil)
        uri = URI(url)
        Net::HTTP::Post.new(uri).tap do |request|
          request["Content-Type"] = "application/json"
          request["Session-Id"] = session_id.to_s unless session_id.to_s.empty?
          request.body = JSON.generate(body)
        end
      end

      def get_request(uri) = Net::HTTP::Get.new(uri)

      def model_entries(body)
        return [] unless body.is_a?(Hash)

        entries = body["data"].is_a?(Array) ? body["data"] : body["models"]
        Array(entries).select { |entry| entry.is_a?(Hash) }
      end

      def model_info(raw)
        id = (raw["id"] || raw["model"] || raw["name"]).to_s
        ModelInfo.new(id: id, context_window: window_of(raw), supports_tools: tools_support(raw), raw: raw)
      end

      # The running window when the list says: context_length, context_window,
      # max_model_len, or llama.cpp's meta.n_ctx (not n_ctx_train).
      def window_of(raw)
        [raw["context_length"], raw["context_window"], raw["max_model_len"], raw.dig("meta", "n_ctx")].each do |value|
          return value if value.is_a?(Integer) && value.positive?
        end
        nil
      end

      def tools_support(raw)
        listed = raw["supported_parameters"] || raw["capabilities"]
        return nil unless listed.is_a?(Array)

        listed.include?("tools") ? true : nil
      end

      def cached_models
        @models_mutex.synchronize do
          fresh = @models_at && (monotonic - @models_at) < @models_ttl
          return @models if fresh
        end
        models = list_models
        @models_mutex.synchronize do
          @models = models
          @models_at = monotonic
        end
        models
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Streamed deltas put together: text, reasoning, tool calls by index,
      # the finish reason, the usage chunk and the served model.
      class Assembly
        # The chunk carries part of a tool call.
        def self.tool_call_delta?(payload)
          choice = payload["choices"].is_a?(Array) ? payload["choices"].first : nil
          choice.is_a?(Hash) && choice["delta"].is_a?(Hash) && !Array(choice["delta"]["tool_calls"]).empty?
        end

        def initialize
          @text = +""
          @reasoning = +""
          @calls = {}
          @finish_reason = nil
          @usage = nil
          @model = nil
        end

        # @return [Array(String, String)] this chunk's content and reasoning
        def add(payload)
          @usage = Usage.from_payload(payload) || @usage if payload.key?("usage")
          @model = OpenAIChat.served_model(payload) || @model
          choice = payload["choices"].is_a?(Array) ? payload["choices"].first : nil
          return ["", ""] unless choice.is_a?(Hash)

          @finish_reason = choice["finish_reason"] if choice["finish_reason"]
          delta = choice["delta"].is_a?(Hash) ? choice["delta"] : {}
          content = delta["content"].to_s
          reasoning = (delta["reasoning_content"] || delta["reasoning"]).to_s
          @text << content
          @reasoning << reasoning
          Array(delta["tool_calls"]).each { |call| add_call(call) }
          [content, reasoning]
        end

        def response
          calls = @calls.sort_by { |index, _| index }.map do |_, call|
            ToolCall.new(id: call[:id], name: call[:name].to_s, arguments: OpenAIChat.parse_arguments(call[:arguments]))
          end
          ChatResponse.new(text: @text, reasoning: @reasoning, tool_calls: calls, usage: @usage || Usage.none,
                           finish_reason: @finish_reason, model: @model)
        end

        private

        def add_call(delta)
          return unless delta.is_a?(Hash)

          index = delta["index"].is_a?(Integer) ? delta["index"] : @calls.size
          call = (@calls[index] ||= { id: nil, name: nil, arguments: +"" })
          call[:id] ||= delta["id"]
          function = delta["function"].is_a?(Hash) ? delta["function"] : {}
          call[:name] ||= function["name"] unless function["name"].to_s.empty?
          call[:arguments] << function["arguments"].to_s
        end
      end
      private_constant :Assembly
    end
  end
end
