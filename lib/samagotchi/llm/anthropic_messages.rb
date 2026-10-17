# frozen_string_literal: true

require "json"
require "uri"
require_relative "../config"
require_relative "../sampling_settings"
require_relative "../thinking"
require_relative "adapter_common"
require_relative "errors"
require_relative "http"
require_relative "model_listing"
require_relative "openai_chat"
require_relative "prompt_cache"
require_relative "refusal_memo"
require_relative "anthropic_assembly"
require_relative "anthropic_wire"
require_relative "dialect"

module Samagotchi
  module LLM
    # Anthropic's Messages API (`POST {base}/v1/messages`: Anthropic's own,
    # a gateway, or a local server such as Splash) on our own HTTP layer, for
    # the same chat loop as OpenAIChat: ChatLoop's OpenAI-shaped wire
    # messages are translated here (AnthropicWire), and the answer comes back
    # as a ChatResponse whose provider_content holds the content blocks to
    # send back verbatim (#replays_content?).
    #
    # A host's dialect (LLM::Dialect, `dialect:`) overrides parts of the
    # standard wire: its default auth header, the thinking `display`, the
    # cache breakpoints and a session-affinity header.
    #
    # Nothing here keys on a model id: fields are sent explicitly, read
    # leniently, and a host's 400 for a field it refuses is what changes a
    # request. Those 400s are handled here, once per request, and
    # remembered for the adapter's life (a host's worker), so ChatLoop's
    # broader refusal paths never see them:
    # - adaptive thinking (or output_config.effort) refused: the model gets
    #   the budget form instead (#budget_form), per model;
    # - thinking.display refused (a provider whose thinking schema has no
    #   such field, e.g. Fireworks without its dialect): no display for the
    #   host, the thinking itself kept;
    # - cache_control refused (Fireworks lists it unsupported): no
    #   breakpoints for the host;
    # - max_tokens over the model's output limit: the limit the message
    #   names, per model.
    # A signature 400 (Claude 5.x preserved thinking: a replayed block bound
    # to a prefix that changed) is recovered here too (#binding_recovery):
    # asked again with drop_block, or with the blocks stripped, and the
    # dropped blocks handed to the loop (ChatResponse#thinking_drop), which
    # removes them from the history.
    class AnthropicMessages
      include ModelListing
      include AdapterCommon

      API_VERSION = "2023-06-01"
      # The budget form's budget_tokens per level (a model that takes no
      # adaptive thinking), and Messages' smallest budget.
      BUDGETS = { low: 2048, medium: 8192, high: 24_576 }.freeze
      MIN_BUDGET = 1024
      # A 400 refusing adaptive thinking or its effort.
      ADAPTIVE_REFUSED_RE = /adaptive|output_config|effort/i
      CACHE_CONTROL_RE = /cache_control/i
      # A 400 refusing the thinking display field: its path (pydantic:
      # "thinking.adaptive.display"), or the field named as unknown or not
      # permitted. Not an error that only echoes the input
      # (input_value={'type': 'adaptive', 'display': ...}).
      DISPLAY_RE = /thinking\.[\w.]*\bdisplay\b|
                    (?:unknown|unexpected|unrecognized|extra|invalid)\s+(?:field|parameter|key|input)s?\W{0,4}display\b|
                    \bdisplay\W{0,4}(?:extra\s+inputs\s+are\s+not\s+permitted|is\s+not\s+(?:permitted|allowed|supported))/xi
      # "max_tokens: 200000 > 128000, which is the maximum allowed number of output tokens for …"
      OUTPUT_CAP_RE = /max_tokens`?:?\s*\d+\s*>\s*(\d+)/i
      # max_tokens when default.max_tokens is unset and the model list names
      # none (a listed one is capped by it too).
      DEFAULT_MAX_TOKENS = 64_000
      # chi's OpenAI-only request fields: never sent to a Messages host
      # (configured sampling passes as written).
      DROPPED_OPTIONS = %i[reasoning_effort chat_template_kwargs stream_options prompt_cache_key logprobs top_logprobs
                           max_completion_tokens].freeze
      # The beta header thinking.block_binding needs, and the behaviour the
      # recovery asks for: the API drops a thinking block whose prefix
      # changed (and every thinking block after it) for that request.
      BINDING_BETA = "thinking-binding-controls-2026-08-01"
      DROP_BLOCK = { prefix_mismatch_behavior: "drop_block" }.freeze
      # A signature 400 that drop_block can settle: the block is valid but
      # bound to another prefix. Without it the signature itself is bad
      # (tampered, unreadable, another provider's): only a strip helps.
      BOUND_ELSEWHERE_RE = /bound to a different conversation/i
      # The block a signature 400 names: an index into the body sent.
      BLOCK_PATH_RE = /messages\.(\d+)\.content\.(\d+)/
      THINKING_TYPES = %w[thinking redacted_thinking].freeze
      # The only drop the loop settles: a model_binding_mismatch (a /model
      # downgrade) keeps its blocks, a switch back reads them again.
      PREFIX_DROP = "prefix_binding_mismatch"

      # One request's binding recovery (#binding_recovery): the step taken
      # (nil, :drop_block or :strip), the steps tried, where a strip starts
      # ([message, block] in the body), the last signature 400 and the body
      # it answered, and the first 400's last sentence and diagnosis for the log line.
      Recovery = Struct.new(:step, :tried, :strip_from, :signature, :why, :diagnosis)

      attr_reader :base_url, :host_name, :api_key_env, :models_ttl, :first_token_timeout, :dialect

      # @param entry [HostRegistry::HostEntry]
      def self.for(entry, **)
        new(base_url: entry.api_base_url, host_name: entry.name, api_key_env: entry.api_key_env, auth: entry.auth,
            dialect: entry.dialect, remote: entry.remote?, **)
      end

      # @param base_url [String] the API root without /v1 (HostEntry#api_base_url)
      # @param auth [Symbol, nil] the header the key goes in (ApiKey::SCHEMES);
      #   nil: the dialect's (x-api-key on the standard one)
      # @param dialect [String, nil] the host's dialect: name (Dialect.for)
      # The rest as OpenAIChat#initialize takes them.
      def initialize(base_url:, host_name:, api_key_env: nil, auth: nil, dialect: nil, stream: true, retries: true,
                     timeout: nil, env: ENV, sleeper: nil, retry_policy: nil, models_ttl: DEFAULT_MODELS_TTL, remote: false,
                     first_token_timeout: nil, purpose: "chat", open_timeout: nil)
        @dialect = Dialect.for(dialect)
        @remote = remote
        @purpose = purpose
        @first_token_timeout = first_token_timeout
        @base_url = base_url.to_s.chomp("/")
        @host_name = host_name.to_s
        @api_key_env = api_key_env
        @stream = stream
        init_model_listing(models_ttl)
        # The 400 fixes (#refusal_fix): :thinking_form and :output_cap per
        # model, :thinking_display and :cache_control for the host.
        @refusals = RefusalMemo.new
        @http = build_http(timeout: timeout, open_timeout: open_timeout, retries: retries, retry_policy: retry_policy,
                           sleeper: sleeper, first_token_timeout: first_token_timeout,
                           api_key: ApiKey.for(api_key_env, host: @host_name, env: env, scheme: auth || @dialect.auth))
      end

      # The same contract as OpenAIChat#chat; +messages+ are ChatLoop's
      # OpenAI-shaped wire messages.
      # @return [ChatResponse]
      def chat(messages:, model:, tools: [], cancel_controller: nil, on_delta: nil, on_retry: nil, options: {},
               session_id: nil)
        fixed = []
        recovery = Recovery.new(tried: [])
        shown = false
        begin
          # A rebuilt body (a refusal fix's retry) keeps the recovery.
          body, stripped = recovered_body(request_body(messages, tools, model, options), recovery)
          headers = recovery.step == :drop_block ? { "anthropic-beta" => BINDING_BETA } : {}
          request = post_request("#{@base_url}/v1/messages", body, session_id: session_id, extra_headers: headers)
          log_fields = { model: model, purpose: @purpose, sampling: sampling_summary(body), cache: cache_summary(body) }
          response, transformations =
            if @stream
              chat_streamed(request, cancel_controller, on_delta, on_retry, log_fields, -> { shown = true })
            else
              chat_once(request, cancel_controller, log_fields)
            end
          recovery.step ? with_thinking_drop(response, recovery, body, stripped, transformations, model) : response
        rescue BadRequest => e
          # Only before anything was shown: a mid-stream error must not
          # repeat its deltas.
          if !shown && binding_recovery(e, body, recovery, model)
            recovery.tried << recovery.step
            retry
          end

          fix = refusal_fix(e, body, model)
          raise if fix.nil? || fixed.include?(fix)

          fixed << fix
          retry
        end
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
      # `thinking: disabled`, low/medium/high adaptive thinking at that
      # effort, shown the dialect's way (summarized; no display field on a
      # dialect that has none).
      # @return [Hash] frozen
      def thinking_fields(level)
        case level
        when :off then { thinking: { type: "disabled" }.freeze }.freeze
        when *Thinking::EFFORTS
          thinking = { type: "adaptive", display: @dialect.thinking_display }.compact.freeze
          { thinking: thinking, output_config: { effort: level.to_s }.freeze }.freeze
        else {}.freeze
        end
      end

      # The thinking fields for a short side answer (a recap, ctx.ask_model,
      # a triage) from a model that refused thinking off: an always-thinking
      # model can't skip it, so it thinks at low effort (IdleClient leaves
      # room for the answer).
      # @return [Hash] frozen
      def thinking_off_refused_fields = thinking_fields(:low)

      # The host's models, every page: GET {base}/v1/models with
      # limit=1000 and after_id paging (has_more/last_id). Anthropic's shape
      # (max_input_tokens, max_tokens, capabilities) and the OpenAI shape a
      # gateway or Splash serves here are both read (ModelListing).
      # Whether +model+ gets the budget form (it refused adaptive thinking).
      def budget_form?(model) = @refusals.refused?(:thinking_form, model.to_s)

      # @return [Array<ModelInfo>]
      def list_models
        list_model_pages { |after| URI("#{@base_url}/v1/models?#{URI.encode_www_form({ limit: 1000, after_id: after }.compact)}") }
      end

      private

      # Anthropic lists the window as max_input_tokens; else the fields an
      # OpenAI-shaped list carries.
      def window_of(raw)
        window = raw["max_input_tokens"]
        window.is_a?(Integer) && window.positive? ? window : super
      end

      # The Messages body: model, max_tokens, the system blocks, the
      # messages, the stream flag, the tools (tool_choice auto with them),
      # then the options as Messages takes them (chi's OpenAI-only fields
      # dropped; a null drops a field).
      def request_body(messages, tools, model, options)
        options = (options || {}).to_h.transform_keys(&:to_sym).except(*DROPPED_OPTIONS)
        options = budget_form(options) if budget_form?(model)
        options = without_display(options) if @refusals.refused?(:thinking_display)
        cache = PromptCache.control if @purpose == "chat" && @dialect.cache_breakpoints && !@refusals.refused?(:cache_control)
        translated = AnthropicWire.translate(messages, cache: cache)
        max_tokens = options.delete(:max_tokens) || default_max_tokens(model)
        output_cap = @refusals[:output_cap, model.to_s]
        max_tokens = [max_tokens, output_cap].min if output_cap
        body = { model: model, max_tokens: max_tokens }
        body[:system] = translated.system unless translated.system.empty?
        body[:messages] = translated.messages
        body[:stream] = @stream
        unless Array(tools).empty?
          body[:tools] = AnthropicWire.tools(tools)
          body[:tool_choice] = { type: "auto" }
        end
        with_budget_room(body.merge(options).compact)
      end

      # Adaptive thinking at a level as the budget form: thinking enabled
      # with BUDGETS' budget (medium without an effort), shown as asked (no
      # display when it asked none), and no effort (a model without
      # adaptive thinking may take none).
      def budget_form(options)
        thinking = options[:thinking].is_a?(Hash) ? options[:thinking].transform_keys(&:to_sym) : nil
        return options unless thinking && thinking[:type].to_s == "adaptive"

        config = options[:output_config].is_a?(Hash) ? options[:output_config].transform_keys(&:to_sym) : {}
        budget = BUDGETS.fetch(config[:effort].to_s.to_sym, BUDGETS[:medium])
        config = config.except(:effort)
        options.merge(thinking: { type: "enabled", budget_tokens: budget, display: thinking[:display] }.compact,
                      output_config: config.empty? ? nil : config)
      end

      # +options+ with no thinking.display (the host refused the field).
      def without_display(options)
        thinking = options[:thinking]
        return options unless thinking.is_a?(Hash)

        options.merge(thinking: thinking.transform_keys(&:to_sym).except(:display))
      end

      # Messages wants max_tokens > budget_tokens (and a budget of at least
      # MIN_BUDGET): a budget without that room is lowered to leave
      # MIN_BUDGET for the answer; below MIN_BUDGET itself, max_tokens is
      # raised to 2 * MIN_BUDGET with the smallest budget.
      def with_budget_room(body)
        thinking = body[:thinking]
        return body unless thinking.is_a?(Hash) && thinking[:budget_tokens].is_a?(Integer)

        budget = thinking[:budget_tokens]
        max_tokens = body[:max_tokens].to_i
        return body if max_tokens > budget + MIN_BUDGET

        budget = max_tokens - MIN_BUDGET
        if budget < MIN_BUDGET
          budget = MIN_BUDGET
          max_tokens = 2 * MIN_BUDGET
        end
        body.merge(max_tokens: max_tokens, thinking: thinking.merge(budget_tokens: budget))
      end

      # The step a signature 400 for +body+ takes (set on +recovery+, once
      # each per request), or nil: the error goes on as it is.
      # - drop_block: the same body with thinking.block_binding and the beta
      #   header, for a block bound to another prefix, when the host takes
      #   the controls and the body's thinking can carry them (adaptive,
      #   enabled, or none: then adaptive; not disabled, nor none for a
      #   model on the budget form);
      # - strip: the block the 400 names (else the first replayed thinking
      #   block) and every thinking block after it removed, for a bad
      #   signature, where drop_block can't apply, when the host refused
      #   the controls (remembered for the host), or after a second
      #   signature 400.
      def binding_recovery(error, body, recovery, model)
        return nil if body.nil? || error.status != 400

        if error.thinking_binding_unsupported? && recovery.step == :drop_block
          unless @refusals.refused?(:binding_controls)
            @refusals.remember(:binding_controls)
            Log.info(:http, "binding_controls_refused", host: @host_name, detail: error.detail.to_s[0, 200])
          end
          return strip_step(recovery)
        end
        return nil unless error.thinking_signature?

        recovery.diagnosis ||= error.diagnosis
        recovery.signature = [error.detail.to_s, body]
        case recovery.step
        when nil
          return nil if thinking_positions(body).empty?

          recovery.why = last_sentence(error.detail.to_s)
          return strip_step(recovery) unless drop_block_fits?(error, body, model)

          recovery.step = :drop_block
        when :drop_block then strip_step(recovery)
        end
      end

      def drop_block_fits?(error, body, model)
        return false unless BOUND_ELSEWHERE_RE.match?(error.detail.to_s) && !@refusals.refused?(:binding_controls)

        case body[:thinking]
        when nil then !budget_form?(model)
        when Hash then %w[adaptive enabled].include?(body[:thinking][:type].to_s)
        else false
        end
      end

      # The strip, from the block the last signature 400 names in the body
      # it answered (a thinking block there), else the first replayed one.
      def strip_step(recovery)
        return nil if recovery.tried.include?(:strip)

        detail, body = recovery.signature
        positions = thinking_positions(body)
        named = detail.to_s.match(BLOCK_PATH_RE)&.captures&.map(&:to_i)
        recovery.strip_from = positions.include?(named) ? named : positions.first
        recovery.step = recovery.strip_from && :strip
      end

      # [message, block] of every thinking or redacted_thinking block in
      # +body+'s messages.
      def thinking_positions(body)
        Array(body[:messages]).each_with_index.flat_map do |message, n|
          Array(message[:content]).each_with_index.filter_map { |block, m| [n, m] if thinking_block?(block) }
        end
      end

      def thinking_block?(block) = block.is_a?(Hash) && THINKING_TYPES.include?((block["type"] || block[:type]).to_s)

      # +body+ as the recovery step sends it, and the identities a strip
      # removed (nil for none).
      def recovered_body(body, recovery)
        case recovery.step
        when :drop_block then [body.merge(thinking: drop_block_thinking(body[:thinking])), nil]
        when :strip then stripped_body(body, recovery.strip_from)
        else [body, nil]
        end
      end

      # The body's thinking with block_binding: drop_block (adaptive
      # without one: the binding controls need adaptive or enabled).
      def drop_block_thinking(thinking)
        thinking = thinking.is_a?(Hash) ? thinking.transform_keys(&:to_sym) : {}
        thinking = { type: "adaptive" } unless %w[adaptive enabled].include?(thinking[:type].to_s)
        thinking.merge(block_binding: DROP_BLOCK)
      end

      # +body+ without the thinking blocks from +from+ on (a trailing run:
      # what Messages takes; a gap in the middle it refuses), and their
      # identities. A message left empty says the placeholder.
      def stripped_body(body, from)
        first_message, first_block = from
        removed = []
        messages = body[:messages].each_with_index.map do |message, n|
          next message if n < first_message

          content = message[:content].each_with_index.reject do |block, m|
            drop = (n > first_message || m >= first_block) && thinking_block?(block)
            removed << AnthropicWire.block_identity(block) if drop
            drop
          end.map(&:first)
          next message if content.size == message[:content].size

          message.merge(content: content.empty? ? [{ type: "text", text: AnthropicWire::PLACEHOLDER }] : content)
        end
        [body.merge(messages: messages), removed.compact.uniq.freeze]
      end

      # +response+ with the blocks this request went without
      # (ThinkingDrop), logged: a strip's, or drop_block's
      # prefix_binding_mismatch entries mapped by path into +body+ (the
      # body sent); any other entry is counted as kept, never settled.
      def with_thinking_drop(response, recovery, body, stripped, transformations, model)
        if recovery.step == :strip
          identities = stripped
          kept = 0
        else
          drops = Array(transformations).select { |entry| entry["type"] == "thinking_dropped" }
          prefix, others = drops.partition { |entry| entry["reason"] == PREFIX_DROP }
          identities = prefix.filter_map { |entry| identity_at(body, entry["path"]) }.uniq.freeze
          kept = others.size
        end
        fields = { host: @host_name, model: model.to_s, how: recovery.step.to_s, dropped: identities.size,
                   kept: kept, why: recovery.why }
        fields[:diagnosis] = recovery.diagnosis if recovery.diagnosis
        Log.info(:http, "thinking_recovered", **fields)
        return response if identities.empty?

        response.with(thinking_drop: ThinkingDrop.new(identities: identities, how: recovery.step))
      end

      def identity_at(body, path)
        n, m = path.to_s.match(BLOCK_PATH_RE)&.captures&.map(&:to_i)
        return nil unless n

        block = Array(body[:messages])[n]&.then { |message| Array(message[:content])[m] }
        thinking_block?(block) ? AnthropicWire.block_identity(block) : nil
      end

      # The last sentence of a 400 (what it says changed: "The `system`
      # prompt differs …"), at most 200 characters.
      def last_sentence(detail)
        detail.strip.split(/(?<=\.)\s+/).last.to_s[0, 200]
      end

      # What a 400 for +body+ changes (remembered), or nil: the error goes
      # on as it is.
      def refusal_fix(error, body, model)
        return nil if error.context_overflow? || error.status != 400 || body.nil?
        # Those are the loop's (a sampling field) or P3's (signatures,
        # binding controls): a mention of "effort" in them is no form refusal.
        return nil if error.sampling_refused? || error.thinking_signature? || error.thinking_binding_unsupported?

        detail = error.detail.to_s
        # Before the adaptive check: the refused field's path
        # ("thinking.adaptive.display") names adaptive too.
        if !@refusals.refused?(:thinking_display) && body[:thinking].is_a?(Hash) && body[:thinking].key?(:display) &&
           DISPLAY_RE.match?(detail)
          @refusals.remember(:thinking_display)
          Log.info(:http, "thinking_display_refused", host: @host_name, detail: detail[0, 200])
          :thinking_display
        elsif body.dig(:thinking, :type) == "adaptive" && ADAPTIVE_REFUSED_RE.match?(detail)
          @refusals.remember(:thinking_form, model.to_s)
          Log.info(:http, "thinking_form_switched", host: @host_name, model: model.to_s, to: "budget", detail: detail[0, 200])
          :thinking_form
        elsif !@refusals.refused?(:cache_control) && CACHE_CONTROL_RE.match?(detail) && cache_summary(body)
          @refusals.remember(:cache_control)
          Log.info(:http, "cache_control_refused", host: @host_name, detail: detail[0, 200])
          :cache_control
        elsif (cap = detail[OUTPUT_CAP_RE, 1]&.to_i) && cap.positive? && body[:max_tokens].to_i > cap
          @refusals.remember(:output_cap, model.to_s, cap)
          Log.info(:http, "output_cap", host: @host_name, model: model.to_s, max_tokens: cap)
          :max_tokens
        end
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

        assembly = AnthropicAssembly.from_message(body)
        [assembly.response, assembly.input_transformations]
      end

      def message?(body) = body.is_a?(Hash) && body["content"].is_a?(Array)

      # The SSE stream: each `data:` event goes through the assembly (the
      # `event:` lines are not needed, so a gateway that drops them works);
      # on_delta gets every event but pings, with its text and reasoning;
      # +on_shown+ hears each event that shows something. Returns the
      # response and the message's input_transformations.
      def chat_streamed(request, cancel_controller, on_delta, on_retry, log_fields, on_shown = nil)
        last = nil
        response = stream_assembled(request, cancel_controller, on_retry, log_fields, assembly_class: AnthropicAssembly,
                                                                                      what: "stream event") do |assembly, event, shown|
          last = assembly
          content, reasoning = assembly.add(event)
          if AnthropicAssembly.shows?(event)
            shown.call
            on_shown&.call
          end
          on_delta&.call(content: content, reasoning: reasoning, payload: assembly.with_usage(event)) unless event["type"] == "ping"
        end
        [response, last&.input_transformations || []]
      end

      # +extra_headers+ go after the defaults (the binding beta).
      def post_request(url, body, session_id: nil, extra_headers: {})
        headers = { "anthropic-version" => API_VERSION }
        unless session_id.to_s.empty?
          headers["Session-Id"] = session_id.to_s
          headers[@dialect.session_header] = session_id.to_s if @dialect.session_header
        end
        json_post(url, body, headers.merge(extra_headers))
      end
    end
  end
end
