# frozen_string_literal: true

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
      # rendered from.
      def tool_definitions
        ToolDeclarations::TOOL_SCHEMAS.map do |schema|
          { type: "function", function: schema.slice(:name, :description, :parameters) }
        end
      end

      # engine-format conversation -> OpenAI wire messages. Tool responses
      # carry their tool_call_id; model turns are thought-stripped; user
      # content goes as parts (a String is wrapped in a text part).
      def wire_messages(conversation)
        conversation.map do |entry|
          case entry[:role].to_s
          when "system"
            { role: "system", content: entry[:content].to_s }
          when "user"
            { role: "user", content: parts(entry[:content]) }
          when "model"
            { role: "assistant", content: strip_model_thought(entry[:content].to_s) }
          when "tool_response"
            message = { role: "tool", content: entry[:content].to_s }
            message[:tool_call_id] = entry[:tool_call_id] if entry[:tool_call_id]
            message
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
      # points at (Engine keeps it on the effective model's host), then
      # config, env and the default.
      def context_window(model)
        client = @kernel.client if @kernel.respond_to?(:client)
        ContextWindow.resolve(client: client, model: model)
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

      # The {role:, content:} shape the engine persists.
      def plain(conversation)
        conversation.map { |entry| { role: entry[:role], content: entry[:content].to_s } }
      end

      private

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
              next if inject_pending_input(iteration)

              @conversation << { role: "model", content: last_text } unless last_text.empty?
              exhausted = false
              break
            end

            @conversation << { role: "model", content: last_text } unless last_text.empty?
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
          emit(type: :generation_completed, iteration: iteration, content_length: response.text.length)
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
        # Returns true when there was any.
        def inject_pending_input(iteration)
          return false unless @pending_input

          lines = begin
            @pending_input.call
          rescue StandardError
            nil
          end
          return false if lines.nil? || lines.empty?

          content = lines.map { |line| line.to_s.strip }.reject(&:empty?).join("\n\n")
          return false if content.empty?

          @conversation << { role: "user", content: content }
          emit(type: :pending_input_merged, iteration: iteration, count: lines.length, content: content)
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
