# frozen_string_literal: true

require_relative "backend"
require_relative "model_result"
require_relative "../client"
require_relative "native_tool_normalizer"
require_relative "../kernel_loop"
require_relative "../context_window"
require_relative "../tool_activity"
require_relative "../tool_runner"
require_relative "../tool_declarations"

require "ruby_llm"
require "json"

module Samagotchi
  module LLM
    # Provider backend that talks to a ruby_llm gem (OpenAI-compatible endpoint).
    #
    # Phase 2 (this class's first incarnation) was single-pass text-only. Phase 3
    # adds an AGENTIC TOOL-ROUND LOOP: when the server returns a native OpenAI
    # tool call, the harness executes it through the shared `KernelLoop#dispatch`
    # path and feeds the result back, looping until the model stops calling tools
    # or `max_iterations` is reached.
    #
    # ── WHY a raw per-iteration request (and not gem `Chat#complete`) ──────────
    # The gem's `Chat#complete` *auto-executes* registered tools internally
    # (`complete_once` → `handle_tool_calls` → `execute_tool`), consuming the
    # tool call and recursing — so it NEVER returns a structured tool call to the
    # caller. Its `format_messages` also drops `tool_call_id`, which OpenAI wire
    # format requires for tool responses. Either way the gem's own completion path
    # hides the tool call from us.
    #
    # Spike #4 proved the reliable driver is a **raw in-body** tools request to the
    # OpenAI-compatible endpoint. `render_payload` builds the `tools` field only
    # from a Hash of registered `RubyLLM::Tool` objects (the gem's `tool_for`
    # requires a non-null description), and a *null* description makes the *server*
    # hard-reject the request — so we inject `tools` in-body via the `params` merge.
    #
    # The base `Provider#complete` / `Connection#post` do NOT auto-handle tools and
    # the sync `Message` exposes both `.content` and parsed `.tool_calls` — exactly
    # what this loop needs.
    #
    # Statelessness, by design: every iteration issues a FRESH request built from
    # the accumulated `conversation` (engine-format, the single source of truth).
    # No gem `Chat` is held between iterations — every iteration re-seeds from the
    # accumulated conversation, mirroring the engine's single-turn-per-iteration
    # discipline and fixing the "dual source of truth" reviewer gap.
    #
    # Cancellation: the gem exposes NO cancel API. A peer
    # `Samagotchi::Client::CancellationController` listener raises
    # `RequestCancelled` into the dedicated request thread while it is blocked in a
    # Faraday socket read. Each iteration spawns its own thread + listener (Phase 2's
    # proven pattern); an inter-tool cancel is caught by a cancel check before each
    # seed. On the main thread we cannot `Thread#raise` into it, so we run inline
    # and let completion finish (graceful degradation — no crash).
    class RubyLLMBackend < ModelBackend
      TOOL_RESPONSE_JOIN = "\n\n---\n\n".freeze

      def initialize(model_name:, gem_provider: :openai, assume_model_exists: true, kernel: nil, base_url: nil)
        @model_name = model_name
        @assume_model_exists = assume_model_exists
        @kernel = kernel
        @base_url = base_url.to_s.chomp("/") unless base_url.nil?
      end

      def provider = :ruby_llm

      attr_reader :base_url

      # Engine points the backend at the effective model's host each turn and
      # on /model; the gem provider is rebuilt for a new endpoint.
      def base_url=(url)
        url = url.to_s.chomp("/") unless url.nil?
        return if url == @base_url

        @base_url = url
        @gem_provider = nil
      end

      def complete(messages:, max_iterations: 100, on_stream_event: nil, cancel_controller: nil,
                   model_name: nil, max_tool_output_chars: nil, pending_input: nil)
        # Fast path: a pre-set cancel means nothing ran, so the conversation is
        # simply the inbound messages unchanged (nothing was appended).
        if cancel_controller&.cancelled?
          return Samagotchi::LLM::ModelResult.new(
            text: "", tool_calls: nil, provider: :ruby_llm,
            conversation: Array(messages).map { |e| { role: e[:role], content: e[:content].to_s } },
            canceled: true,
            cancellation_reason: cancel_controller.reason
          )
        end

        run_tool_loop(
          Array(messages),
          max_iterations: max_iterations,
          on_stream_event: on_stream_event,
          cancel_controller: cancel_controller,
          model_name: model_name,
          max_tool_output_chars: max_tool_output_chars,
          pending_input: pending_input
        )
      end

      private

      # Runs the agentic tool-round loop and returns a finished ModelResult. The
      # loop lives INSIDE the backend; raw provider tool calls are never surfaced
      # — `tool_calls` is always `nil` downstream.
      def run_tool_loop(seed_messages, max_iterations:, on_stream_event:, cancel_controller:,
                        model_name:, max_tool_output_chars:, pending_input: nil)
        effective_max_tool_output_chars = resolve_output_char_cap(max_tool_output_chars)
        conversation = seed_messages.map { |e| { role: e[:role], content: e[:content].to_s } }
        last_text = ""
        tool_activity = []
        # Default true: if we never hit the no-tool-call `break`, the loop stopped
        # because max_iterations was reached (criterion #7 → exhausted, not errored).
        reached_cap = true

        (max_iterations || 1).times do |iteration_index|
          # Inter-tool cancel guard: a cancel that arrived during tool dispatch
          # (between generations) is caught before we seed the next request.
          if cancel_controller&.cancelled?
            emit_stream_event(on_stream_event, type: :generation_cancelled,
                                               iteration: iteration_index + 1,
                                               reason: cancel_controller.reason)
            return build_result("", canceled: true, reason: cancel_controller.reason,
                                conversation: conversation, tool_activity: tool_activity)
          end

          inject_pending_input!(conversation, pending_input, on_stream_event, iteration_index + 1)

          window = context_window(model_name)
          emit_stream_event(on_stream_event, type: :generation_started, iteration: iteration_index + 1,
                                             context_window_tokens: window&.tokens,
                                             context_window_source: window&.source)
          outcome = generate_once(conversation, on_stream_event, cancel_controller, model_name)

          if outcome.is_a?(Array) && outcome.first == :canceled
            emit_stream_event(on_stream_event, type: :generation_cancelled,
                                               iteration: iteration_index + 1,
                                               reason: outcome[1])
            return build_result("", canceled: true, reason: outcome[1], conversation: conversation,
                                    tool_activity: tool_activity)
          end

          last_text = outcome[:content]
          # One generation == one chunk + one completion, matching the kernel-loop
          # event contract the terminal consumes (thinking-spinner lifecycle:
          # :generation_started starts it, :generation_completed stops it).
          emit_stream_event(on_stream_event, type: :generation_chunk, iteration: iteration_index + 1,
                                             content: last_text, payload: nil)
          emit_stream_event(on_stream_event, type: :generation_completed, iteration: iteration_index + 1,
                                             content_length: last_text.length, payload: nil)
          tool_calls = outcome[:tool_calls]

          if tool_calls.nil? || tool_calls.empty?
            # Queued steering keeps the turn going: inject and loop again so the
            # model answers the message instead of stopping at a clean answer.
            if inject_pending_input!(conversation, pending_input, on_stream_event, iteration_index + 1)
              next
            end
            # Pure-text final generation: preserve the model's answer as a model
            # turn so the engine persists it in result.conversation (the tool
            # branch appends mixed-text turns earlier; this handles the terminal
            # no-tool case). The final text is also returned as result.text.
            final_text = strip_model_thought(last_text)
            conversation << { role: "model", content: final_text } unless final_text.empty?
            # Natural completion (a clean answer with no further tool call).
            reached_cap = false
            break
          end

          # Preserve the model's accompanying text (mixed text + tool call) as a
          # model turn so it isn't lost — the tool call itself is dispatched, not
          # re-emitted ("no double-handling").
          text = strip_model_thought(last_text)
          conversation << { role: "model", content: text } unless text.empty?

          output_by_id = dispatch_tool_calls(tool_calls, on_stream_event,
                                             iteration_index + 1, effective_max_tool_output_chars, tool_activity)

          # Feed each result back as a gem tool-response keyed by its tool_call_id.
          output_by_id.each do |call_id, output|
            conversation << { role: "tool_response", content: output, tool_call_id: call_id }
          end
        end

        build_result(strip_model_thought(last_text), canceled: false, reason: nil,
                     conversation: conversation, exhausted: reached_cap, tool_activity: tool_activity)
      end

      # Drain the pending input queue (if any) and, when messages are waiting,
      # append them as ONE merged user message at the conversation tail (prefix
      # KV cache preserved) and emit :pending_input_merged. Returns true when a
      # message was injected.
      def inject_pending_input!(conversation, pending_input, on_stream_event, iteration)
        return false unless pending_input

        lines = begin
          pending_input.call
        rescue StandardError
          nil
        end
        return false if lines.nil? || lines.empty?

        content = lines.map { |line| line.to_s.strip }.reject(&:empty?).join("\n\n")
        return false if content.empty?

        conversation << { role: "user", content: content }
        emit_stream_event(on_stream_event, type: :pending_input_merged,
                                           iteration: iteration,
                                           count: lines.length,
                                           content: content)
        true
      end

      # Issues ONE generation against the gem and parses the sync Message.
      # Returns {:content => String, :tool_calls => Hash{id => RubyLLM::ToolCall}}.
      # Raises `Samagotchi::Client::RequestCancelled` when the request thread is
      # interrupted (Phase 2's Thread#raise pattern) so the caller can surface a
      # clean canceled result with no dangling assistant/tool turn.
      def generate_once(conversation, on_stream_event, cancel_controller, model_name)
        return [:canceled, cancel_controller.reason] if cancel_controller&.cancelled?

        if Thread.current == Thread.main
          # On the main thread we cannot raise into a socket read, so the gem
          # finishes; a cancel that lands during an inline generation degrades
          # gracefully — the completion runs and returns a valid result (no crash).
          # An inter-tool cancel is still caught at the top of the next loop.
          result = issue_generation(conversation, model_name)
          result
        else
          spawn_request_thread(conversation, model_name, cancel_controller)
        end
      end

      # Spawns the request thread, registers the cancel listener, and joins.
      # Returns [:ok, {content:, tool_calls:}] or [:canceled, reason].
      def spawn_request_thread(conversation, model_name, cancel_controller)
        request_thread_holder = {}
        request_thread_holder[:thread] = Thread.new do
          issue_generation(conversation, model_name)
        rescue Samagotchi::Client::RequestCancelled => e
          [:canceled, e.reason]
        end
        listener_id = cancel_controller&.on_cancel do |cancel_reason|
          target = request_thread_holder[:thread]
          target&.raise(Samagotchi::Client::RequestCancelled.new(cancel_reason))
        end
        thread = request_thread_holder[:thread]
        begin
          thread.join
          thread.value
        ensure
          cancel_controller&.remove_listener(listener_id)
        end
      end

      # Builds the raw OpenAI request body (fresh each iteration) and POSTs it.
      # `tools` is injected in-body via the params merge (render_payload only builds
      # it from registered Tool objects — that path also rejects null descriptions).
      def issue_generation(conversation, model_name)
        provider = gem_provider
        body = build_request_body(conversation, model_name)
        endpoint = "#{provider.api_base}/chat/completions"
        response = provider.connection.post(endpoint, body)
        parse_sync_response(response)
      rescue Samagotchi::Client::RequestCancelled
        raise
      end

      # Parses the sync OpenAI chat-completions response into {:content, :tool_calls}.
      def parse_sync_response(response)
        body = response.respond_to?(:body) ? response.body : response
        body = JSON.parse(body) if body.is_a?(String)
        message_data = body.is_a?(Hash) ? body.dig("choices", 0, "message") : nil
        raise GenerationError, "no message in ruby_llm response" unless message_data

        content = message_data["content"].to_s
        tool_calls =
          if message_data["tool_calls"] && message_data["tool_calls"].any?
            RubyLLM::Providers::OpenAI::Tools.parse_tool_calls(message_data["tool_calls"])
          end
        { content: content, tool_calls: tool_calls }
      end

      # engine-format conversation -> OpenAI wire messages. Tool responses carry
      # their `tool_call_id`; model turns are thought-stripped.
      # Supports multimodal content: content can be a String (text-only) or an
      # Array of content parts (text + image_url for vision models).
      def wire_messages(conversation)
        conversation.map do |entry|
          case entry[:role]
          when "system"
            { role: "system", content: entry[:content].to_s }
          when "user"
            { role: "user", content: format_content(entry[:content]) }
          when "model"
            { role: "assistant", content: strip_model_thought(entry[:content].to_s) }
          when "tool_response"
            msg = { role: "tool", content: entry[:content].to_s }
            msg[:tool_call_id] = entry[:tool_call_id] if entry[:tool_call_id]
            msg
          else
            { role: entry[:role].to_s, content: format_content(entry[:content]) }
          end
        end
      end

      # Formats content for the OpenAI wire format. If content is already an
      # array (multimodal), returns it as-is. Otherwise wraps it in a text part.
      def format_content(content)
        if content.is_a?(Array)
          content
        else
          [{ type: "text", text: content.to_s }]
        end
      end

      # The tool definitions sent in the request body: the same schemas the
      # native prompts are rendered from (ToolDeclarations::TOOL_SCHEMAS).
      def tool_definitions
        ToolDeclarations::TOOL_SCHEMAS.map do |schema|
          { type: "function", function: schema.slice(:name, :description, :parameters) }
        end
      end

      def build_request_body(conversation, model_name)
        {
          model: model_name || @model_name,
          temperature: 0.0,
          messages: wire_messages(conversation),
          tools: tool_definitions,
          tool_choice: "auto"
        }
      end

      # Dispatch each normalized call through the shared KernelLoop path, applying
      # the per-output char cap and emitting the tool-call events. Returns a
      # {call_id => output_string} map keyed by the gem tool_call id.
      def dispatch_tool_calls(tool_calls, on_stream_event, iteration, max_tool_output_chars, tool_activity)
        calls = NativeToolNormalizer.normalize_all(tool_calls.values)
        emit_stream_event(on_stream_event, type: :tool_dispatch_started, iteration: iteration, call_count: calls.length)
        output_by_id = {}
        calls.each_with_index do |call, call_index|
          call_id, _tool_call = tool_calls.to_a[call_index]
          output_by_id[call_id] = dispatch_one(call, on_stream_event, iteration, calls.length, call_index,
                                               max_tool_output_chars, tool_activity)
        end
        emit_stream_event(on_stream_event, type: :tool_dispatch_completed, iteration: iteration, call_count: calls.length)
        output_by_id
      end

      def dispatch_one(call, on_stream_event, iteration, call_count, call_index, max_tool_output_chars, tool_activity)
        run = tool_runner.run(call, iteration: iteration, call_index: call_index + 1, call_count: call_count,
                                    on_stream_event: on_stream_event, max_tool_output_chars: max_tool_output_chars)
        tool_activity << run[:activity] if run[:activity]
        # The chat loop feeds the model the capped output (native feeds the
        # full one); unifying the cap is a P2 decision.
        run[:capped_output]
      end

      def tool_runner
        @tool_runner ||= ToolRunner.new(@kernel)
      end

      def gem_provider
        @gem_provider ||= RubyLLM::Providers::OpenAI.new(ruby_llm_config)
      end

      def ruby_llm_config
        return RubyLLM.config if @base_url.nil? || @base_url.empty?

        config = RubyLLM::Configuration.new
        config.openai_api_base = @base_url
        config.openai_api_key = RubyLLM.config.openai_api_key || "sk-local-dummy"
        config
      end

      # The same resolution native uses: the kernel's client probes the server
      # it points at (Engine keeps it on the effective model's host), then
      # config, env and the default.
      def context_window(model_name)
        client = @kernel.client if @kernel.respond_to?(:client)
        ContextWindow.resolve(client: client, model: model_name || @model_name)
      rescue StandardError
        nil
      end

      def resolve_output_char_cap(override)
        KernelLoop.resolve_output_char_cap(override)
      end

      def strip_model_thought(text)
        @kernel ? @kernel.strip_model_thought(text) : text
      end

      def build_result(text, canceled:, reason:, conversation:, exhausted: false, tool_activity: [])
        Samagotchi::LLM::ModelResult.new(
          text: text,
          tool_calls: nil,
          provider: :ruby_llm,
          # Strip the in-flight tool_call_id so the returned conversation has the
          # plain {role:, content:} shape the engine persists / the UI renders.
          conversation: conversation.map { |e| { role: e[:role], content: e[:content].to_s } },
          canceled: canceled,
          cancellation_reason: reason,
          exhausted: exhausted,
          tool_activity: tool_activity
        )
      end

      def emit_stream_event(callback, event)
        callback&.call(event)
      rescue StandardError
        nil
      end

      # Raised when a generation returns no parseable assistant message.
      class GenerationError < StandardError; end
    end
  end
end
