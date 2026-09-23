# frozen_string_literal: true

require "json"
require_relative "backend"
require_relative "model_result"
require_relative "errors"
require_relative "usage"
require_relative "openai_chat"
require_relative "native_tool_normalizer"
require_relative "../kernel_loop"
require_relative "../context_window"
require_relative "../tool_runner"
require_relative "../tool_declarations"

module Samagotchi
  module LLM
    # The chat loop: the model gets the conversation as chat messages plus
    # function schemas, and calls tools natively. Each iteration is one
    # streamed request through the adapter (OpenAIChat) built from the
    # accumulated conversation; tool calls run through ToolRunner (the same
    # events, hooks and veto as the native loop) and their results go back as
    # tool messages, until the model answers without a tool call or
    # max_iterations is reached.
    #
    # Stream events match the native loop's: :generation_started (with the
    # context window), :generation_chunk per delta, :generation_completed,
    # :generation_retrying, the tool-call events and :pending_input_merged.
    # A chunk carries `thinking:` (reasoning deltas), `text:` (answer deltas)
    # and `content:` (both, like native raw content) plus the raw `payload:`.
    #
    # Cancel closes the request's socket (LLM::HTTP), so it works on any
    # thread; the text streamed so far is kept, marked [interrupted].
    class ChatLoop < ModelBackend
      attr_accessor :adapter

      # @param kernel [KernelLoop] tool dispatch, thought stripping, hooks
      # @param adapter [OpenAIChat, nil] the host to talk to; Engine sets it
      #   per turn for the effective model's host
      def initialize(kernel:, adapter: nil)
        @kernel = kernel
        @adapter = adapter
      end

      def provider = :chat

      def complete(messages:, max_iterations: 100, on_stream_event: nil, cancel_controller: nil,
                   model_name: nil, max_tool_output_chars: nil, pending_input: nil)
        raise ArgumentError, "ChatLoop has no adapter" unless @adapter

        conversation = Array(messages).map(&:dup)
        Run.new(self, conversation, on_stream_event, cancel_controller, model_name, pending_input)
           .call(max_iterations: max_iterations || 1, cap: KernelLoop.resolve_output_char_cap(max_tool_output_chars))
      rescue StandardError => e
        FailedTurn.attach(e, conversation && plain(conversation))
        raise
      end

      # Tool definitions for the request: the schemas the native prompts are
      # rendered from, with the chat-only enums and closed parameters.
      def tool_definitions
        ToolDeclarations.chat_schemas.map do |schema|
          { type: "function", function: schema.slice(:name, :description, :parameters) }
        end
      end

      # engine-format conversation -> OpenAI wire messages. Model turns are
      # thought-stripped and carry their tool_calls; tool responses go as tool
      # messages with their tool_call_id; user content goes as parts (a String
      # is wrapped in a text part).
      #
      # The API rejects an assistant tool call without its tool message (and
      # the reverse), so calls and results that don't pair up are sent as
      # text instead: one broken turn must not fail every later request. A
      # tool result without an id (native or older chat history) goes as a
      # user message "[tool results]\n…", valid on every server.
      def wire_messages(conversation)
        paired = paired_call_ids(conversation)
        conversation.map do |entry|
          case entry[:role].to_s
          when "system"
            { role: "system", content: entry[:content].to_s }
          when "user"
            { role: "user", content: parts(entry[:content]) }
          when "model"
            assistant_message(entry, paired)
          when "tool_response"
            id = entry[:tool_call_id]
            if id && paired.include?(id)
              { role: "tool", content: entry[:content].to_s, tool_call_id: id }
            else
              { role: "user", content: "[tool results]\n#{entry[:content]}" }
            end
          else
            { role: entry[:role].to_s, content: parts(entry[:content]) }
          end
        end
      end

      def strip_model_thought(text)
        @kernel.respond_to?(:strip_model_thought) ? @kernel.strip_model_thought(text) : text
      end

      def tool_runner
        @tool_runner ||= ToolRunner.new(@kernel)
      end

      # The window for +model+: the kernel's client probes the server it
      # points at (Engine keeps it on the effective model's host; a local
      # llama.cpp answers /props), then the host's model list, config, env
      # and the default. A remote provider has no /props to probe.
      def context_window(model)
        remote = @adapter.respond_to?(:remote?) && @adapter.remote?
        client = @kernel.client if !remote && @kernel.respond_to?(:client)
        ContextWindow.resolve(client: client, model: model, adapter: @adapter)
      rescue StandardError
        nil
      end

      # A hook failing must not break the turn (as in ToolRunner).
      def fire_hook(name, event)
        hooks = @kernel.hooks if @kernel.respond_to?(:hooks)
        hooks&.fire(name, event)
      rescue StandardError
        nil
      end

      # The shape the engine persists: role and content (parts stay an
      # Array), plus a model turn's tool_calls and a result's tool_call_id.
      def plain(conversation)
        conversation.map do |entry|
          content = entry[:content].is_a?(Array) ? entry[:content] : entry[:content].to_s
          message = { role: entry[:role], content: content }
          message[:tool_calls] = entry[:tool_calls] if entry[:tool_calls].is_a?(Array) && !entry[:tool_calls].empty?
          message[:tool_call_id] = entry[:tool_call_id] if entry[:tool_call_id]
          message
        end
      end

      private

      # Ids of the calls whose assistant turn is followed by a tool message
      # for every one of them (before the next non-tool message).
      def paired_call_ids(conversation)
        paired = []
        conversation.each_with_index do |entry, index|
          ids = Array(entry[:tool_calls]).map { |call| call[:id] }.compact
          next if entry[:role].to_s != "model" || ids.empty?

          answered = conversation[(index + 1)..].take_while { |next_entry| next_entry[:role].to_s == "tool_response" }
                                                .map { |next_entry| next_entry[:tool_call_id] }
          paired.concat(ids) if (ids - answered).empty?
        end
        paired
      end

      def assistant_message(entry, paired)
        text = strip_model_thought(entry[:content].to_s)
        calls = Array(entry[:tool_calls])
        return { role: "assistant", content: text } if calls.empty?

        if calls.all? { |call| paired.include?(call[:id]) }
          { role: "assistant", content: text.empty? ? nil : text,
            tool_calls: calls.map { |call| wire_call(call) } }
        else
          flat = calls.map { |call| "[tool call] #{call[:name]} #{wire_arguments(call[:arguments])}" }
          { role: "assistant", content: [text, *flat].reject(&:empty?).join("\n") }
        end
      end

      def wire_call(call)
        { id: call[:id], type: "function", function: { name: call[:name].to_s, arguments: wire_arguments(call[:arguments]) } }
      end

      # The API wants arguments as a JSON string; a raw (invalid) one stays.
      def wire_arguments(arguments)
        arguments.is_a?(String) ? arguments : JSON.generate(arguments || {})
      end

      def parts(content)
        content.is_a?(Array) ? content : [{ type: "text", text: content.to_s }]
      end

      # One turn's state: the conversation, the stream sink, usage and tool
      # activity.
      class Run
        def initialize(loop, conversation, on_stream_event, cancel_controller, model_name, pending_input)
          @loop = loop
          @conversation = conversation
          @on_stream_event = on_stream_event
          @cancel_controller = cancel_controller
          @model_name = model_name
          @pending_input = pending_input
          @usage = UsageCollector.new
          @tool_activity = []
          # What an estimate counts as the prompt when the server reports no usage.
          @prompt_text = conversation.sum("") { |entry| entry[:content].to_s }
        end

        EMPTY_ANSWER = "(the model returned an empty answer)"

        def call(max_iterations:, cap:)
          last_text = ""
          exhausted = true
          max_iterations.times do |index|
            iteration = index + 1
            return canceled(iteration, @cancel_controller.reason) if @cancel_controller&.cancelled?

            inject_pending_input(iteration)
            response, partial = generate(iteration)
            return canceled(iteration, response, partial) if partial

            last_text = @loop.strip_model_thought(response.text)
            if response.tool_calls.empty?
              # Kept before a merge too: the model answers the merged line
              # knowing what it just said.
              @conversation << { role: "model", content: last_text } unless last_text.empty?
              next if inject_pending_input(iteration, answer: last_text)

              # Shown, not saved: an empty answer (content "" + stop, seen from
              # a remote host) would otherwise end the turn with nothing.
              last_text = EMPTY_ANSWER if last_text.empty?
              exhausted = false
              break
            end

            # The calls are kept with the turn (even with no text) so the next
            # request, and a resumed session, can pair them with their results.
            @conversation << { role: "model", content: last_text,
                               tool_calls: response.tool_calls.map { |call| { id: call.id, name: call.name, arguments: call.arguments } } }
            last_text = ""
            dispatch(response.tool_calls, iteration, cap)
          end
          result(last_text, exhausted: exhausted)
        end

        private

        # One streamed request. Returns [response, nil], or [reason, partial
        # text] when it was cancelled.
        def generate(iteration)
          window = @loop.context_window(@model_name)
          emit(type: :generation_started, iteration: iteration, context_window_tokens: window&.tokens,
               context_window_source: window&.source)
          @loop.fire_hook(:before_generation, { type: :before_generation, iteration: iteration })
          streamed = +""
          response = @loop.adapter.chat(
            messages: @loop.wire_messages(@conversation), tools: @loop.tool_definitions, model: @model_name,
            cancel_controller: @cancel_controller,
            on_delta: lambda { |content:, reasoning:, payload:|
              streamed << content
              emit(type: :generation_chunk, iteration: iteration, content: reasoning + content, text: content,
                   thinking: reasoning, payload: payload)
            },
            on_retry: ->(**retry_event) { emit({ type: :generation_retrying, iteration: iteration }.merge(retry_event)) }
          )
          emit(type: :generation_completed, iteration: iteration, content_length: response.text.length,
               served_model: response.model, requested_model: @model_name)
          @loop.fire_hook(:after_generation, { type: :after_generation, iteration: iteration, response: response.text })
          [response, nil]
        rescue RequestCancelled => e
          [e.reason, streamed]
        end

        def dispatch(tool_calls, iteration, cap)
          emit(type: :tool_dispatch_started, iteration: iteration, call_count: tool_calls.length)
          tool_calls.each_with_index do |tool_call, index|
            call = NativeToolNormalizer.normalize(tool_call)
            run = @loop.tool_runner.run(call, iteration: iteration, call_index: index + 1, call_count: tool_calls.length,
                                              on_stream_event: @on_stream_event, max_tool_output_chars: cap)
            @tool_activity << run[:activity] if run[:activity]
            # The chat loop feeds the model the capped output (native feeds
            # the full one; D-P2-6).
            @conversation << { role: "tool_response", content: run[:capped_output], tool_call_id: tool_call.id }
          end
          emit(type: :tool_dispatch_completed, iteration: iteration, call_count: tool_calls.length)
        end

        # Queued steering joins the conversation as one user message.
        # Returns true when there was any. After a cancel it stays queued, so
        # it runs as the next turn instead of dying with this one. +answer+ is
        # the answer the merge follows, for the UIs.
        def inject_pending_input(iteration, answer: nil)
          return false unless @pending_input
          return false if @cancel_controller&.cancelled?

          lines = begin
            @pending_input.call
          rescue StandardError
            nil
          end
          return false if lines.nil? || lines.empty?

          content = lines.map { |line| line.to_s.strip }.reject(&:empty?).join("\n\n")
          return false if content.empty?

          @conversation << { role: "user", content: content }
          emit(type: :pending_input_merged, iteration: iteration, count: lines.length, content: content,
               answer: answer.to_s.empty? ? nil : answer)
          true
        end

        # The text streamed before the cancel stays, marked [interrupted],
        # as the native loop's salvage does.
        def canceled(iteration, reason, partial = "")
          emit(type: :generation_cancelled, iteration: iteration, reason: reason)
          visible = @loop.strip_model_thought(partial.to_s).strip
          @conversation << { role: "model", content: "#{visible}\n[interrupted]", interrupted: true } unless visible.empty?
          conversation = @loop.plain(@conversation)
          conversation.last[:interrupted] = true unless visible.empty?
          ModelResult.new(text: "", provider: :chat, conversation: conversation, canceled: true,
                          cancellation_reason: reason, tool_activity: @tool_activity, usage: usage)
        end

        def result(text, exhausted:)
          ModelResult.new(text: text, provider: :chat, conversation: @loop.plain(@conversation), exhausted: exhausted,
                          tool_activity: @tool_activity, usage: usage)
        end

        def usage
          @usage.usage(prompt_text: @prompt_text)
        end

        def emit(event)
          @usage.observe(event)
          @on_stream_event&.call(event)
        rescue StandardError
          nil
        end
      end
      private_constant :Run
    end
  end
end
