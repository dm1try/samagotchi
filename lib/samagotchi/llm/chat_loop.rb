# frozen_string_literal: true

require "json"
require_relative "backend"
require_relative "model_result"
require_relative "errors"
require_relative "usage"
require_relative "openai_chat"
require_relative "native_tool_normalizer"
require_relative "../kernel_loop"
require_relative "../answer_display"
require_relative "../context_status"
require_relative "../context_window"
require_relative "../context_note"
require_relative "../tool_runner"
require_relative "../tool_response"
require_relative "../tool_declarations"
require_relative "../vision_context"
require_relative "../log"
require_relative "../empty_answer_retry"
require_relative "../steer"
require_relative "../turn_note"
require_relative "../thinking"

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
      # The session every request is for; Engine sets it with the adapter.
      # Goes out as a Session-Id header (OpenAIChat#chat).
      attr_accessor :session_id

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
      # rendered from (the kernel's registry), with the chat-only enums and
      # closed parameters.
      def tool_definitions
        ToolDeclarations.chat_schemas(tools.schemas).map do |schema|
          { type: "function", function: schema.slice(:name, :description, :parameters) }
        end
      end

      # The kernel's tools; the built-ins for a kernel without a registry.
      def tools
        @kernel.respond_to?(:tools) ? @kernel.tools : Tools::Builtins.default
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
      #
      # Images (+images:+ refs) go as image_url parts after the text. A tool
      # message takes text only, so a run of tool results' images follows it
      # as one user message "[images from tool results]". Images the request
      # leaves out (ImagePlan) become placeholder lines in the text.
      def wire_messages(conversation)
        paired = paired_call_ids(conversation)
        plan = ImagePlan.new(conversation, vision)
        tool_images = []
        wire = []
        conversation.each_with_index do |entry, index|
          items = plan.items(entry, index)
          case entry[:role].to_s
          when "system"
            wire << { role: "system", content: entry[:content].to_s }
          when "user"
            wire << { role: "user", content: parts(entry[:content], items) }
          when "model"
            wire << assistant_message(entry, paired)
          when "tool_response"
            id = entry[:tool_call_id]
            if id && paired.include?(id)
              wire << { role: "tool", content: with_placeholders(entry[:content].to_s, items), tool_call_id: id }
              tool_images.concat(image_parts(items))
            else
              text = "[tool results]\n#{entry[:content]}"
              wire << { role: "user", content: items.empty? ? text : parts(text, items) }
            end
          else
            wire << { role: entry[:role].to_s, content: parts(entry[:content]) }
          end
          next if conversation[index + 1]&.dig(:role).to_s == "tool_response" || tool_images.empty?

          wire << { role: "user", content: [{ type: "text", text: TOOL_IMAGES_TEXT }, *tool_images] }
          tool_images = []
        end
        wire
      end

      TOOL_IMAGES_TEXT = "[images from tool results]"

      # The turn's VisionContext (the Engine sets it on the kernel), or nil.
      def vision
        @kernel.respond_to?(:vision) ? @kernel.vision : nil
      end

      # The turn's request parameters (the Engine sets them on the kernel).
      def sampling
        @kernel.respond_to?(:sampling) ? @kernel.sampling || {} : {}
      end

      # The turn's thinking level (the Engine sets it on the kernel).
      def thinking
        (@kernel.respond_to?(:thinking) && @kernel.thinking) || Thinking::DEFAULT
      end

      # The request fields the thinking level adds (Thinking.chat_fields);
      # none for a model whose host refused them (#thinking_refused!).
      def thinking_fields(model = nil)
        return {} if model && (@thinking_refused ||= Set.new).include?(model)

        Thinking.chat_fields(thinking)
      end

      # The host refused +model+'s thinking fields: leave them out from now on.
      def thinking_refused!(model)
        (@thinking_refused ||= Set.new) << model
      end

      # One generation's options: the thinking fields under the sampling
      # (a sampling key wins, chat_template_kwargs merges per sub-key), the
      # empty-answer retry's temperature on top, then every null dropped at
      # any depth (a sampling null means "don't send it").
      def request_options(retry_generation: false, model: nil)
        options = deep_merge(thinking_fields(model), sampling)
        options = EmptyAnswerRetry.sampling(options) if retry_generation
        deep_compact(options)
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
      # Array), plus a model turn's tool_calls and thinking (the host's
      # reasoning, never sent back), a result's tool_call_id, the image
      # refs of a user message or a tool result, and a plugin tool result's
      # tool_params and tool_labels (the live row's params line and label,
      # never sent back), and an edit/write result's tool_diffs (never sent).
      def plain(conversation)
        conversation.map do |entry|
          content = entry[:content].is_a?(Array) ? entry[:content] : entry[:content].to_s
          message = { role: entry[:role], content: content }
          message[:tool_calls] = entry[:tool_calls] if entry[:tool_calls].is_a?(Array) && !entry[:tool_calls].empty?
          message[:tool_call_id] = entry[:tool_call_id] if entry[:tool_call_id]
          message[:images] = entry[:images] if entry[:images].is_a?(Array) && !entry[:images].empty?
          message[:thinking] = entry[:thinking] if entry[:thinking].is_a?(String) && !entry[:thinking].empty?
          ToolResponse::SAVED_KEYS.each { |key| message[key] = entry[key] if entry[key] }
          message[TurnNote::RETRY_NUDGE] = true if TurnNote.retry_nudge?(entry)
          message[AnswerDisplay::KEY] = entry[AnswerDisplay::KEY] if entry[AnswerDisplay::KEY]
          ContextNote::KEYS.each { |key| message[key] = entry[key] if entry.key?(key) }
          message
        end
      end

      private

      def deep_merge(base, over)
        base.merge(over) { |_key, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b }
      end

      def deep_compact(hash)
        hash.each_with_object({}) do |(key, value), out|
          next if value.nil?

          out[key] = value.is_a?(Hash) ? deep_compact(value) : value
        end
      end

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

      # User content as parts: the text first (scrubbed of invalid UTF-8,
      # with a line per image left out), then the images.
      def parts(content, items = [])
        if content.is_a?(Array)
          notes = with_placeholders("", items)
          return content + (notes.empty? ? [] : [{ type: "text", text: notes }]) + image_parts(items)
        end

        [{ type: "text", text: scrub(with_placeholders(content.to_s, items)) }] + image_parts(items)
      end

      def image_parts(items)
        items.select(&:sent?).map { |item| { type: "image_url", image_url: { url: item.data } } }
      end

      def with_placeholders(text, items)
        notes = items.reject(&:sent?).map(&:placeholder)
        notes.empty? ? text : [text, *notes].reject(&:empty?).join("\n")
      end

      def scrub(text)
        text.encoding == Encoding::UTF_8 && !text.valid_encoding? ? text.scrub("?") : text
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
          # What an estimate counts as the prompt when the server reports no
          # usage: the text, and each image's estimate (not its base64).
          @prompt_text = conversation.sum("") { |entry| entry[:content].to_s }
          @image_tokens = ImagePlan.estimated_tokens(conversation)
          @empty_retry = EmptyAnswerRetry.new
          @context = ContextStatus.new(conversation: conversation)
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

            if response.cut
              outcome = after_cut(iteration, response)
              next if outcome == :retry

              return outcome
            end

            last_text = @loop.strip_model_thought(response.text)
            if response.tool_calls.empty?
              # Only whitespace is no answer either (as in the native loop).
              empty = last_text.strip.empty?
              # Kept before a merge too: the model answers the merged line
              # knowing what it just said.
              @conversation << with_thinking({ role: "model", content: last_text }, response) unless empty
              retry_empty = empty &&
                            @empty_retry.retry_empty?(iteration: iteration, cancelled: @cancel_controller&.cancelled?,
                                                      finish_reason: response.finish_reason,
                                                      used_tokens: response.usage&.total_tokens, window_tokens: @window&.tokens)
              # An empty answer that will be retried is no answer site: a
              # plugin's steer joins the retry instead of being dropped, and
              # queued input (a user's line, a steer) goes in place of the nudge.
              next if inject_pending_input(iteration, answer: retry_empty ? nil : last_text)
              next if retry_empty && nudge_empty_answer(iteration, response)

              # Shown, not saved: an empty answer (content "" + stop, seen from
              # a remote host) would otherwise end the turn with nothing.
              last_text = EMPTY_ANSWER if empty
              exhausted = false
              break
            end

            # The calls are kept with the turn (even with no text) so the next
            # request, and a resumed session, can pair them with their results.
            @conversation << with_thinking({ role: "model", content: last_text,
                                             tool_calls: response.tool_calls.map { |call| { id: call.id, name: call.name, arguments: call.arguments } } },
                                           response)
            last_text = ""
            dispatch(response.tool_calls, iteration, cap)
          end
          result(last_text, exhausted: exhausted)
        end

        private

        # The hidden nudge before the next generation (EmptyAnswerRetry),
        # which runs at the retry temperature. Returns true.
        def nudge_empty_answer(iteration, response)
          @empty_retry.nudge!(@conversation, TurnNote.empty_retry,
                              emit: method(:emit), iteration: iteration, finish_reason: response.finish_reason,
                              thinking_chars: response.reasoning.to_s.length)
        end

        # A generation a plugin cut (stop_generation) is an empty answer made
        # early: asked again with its own nudge while the retry budget lasts
        # (queued input goes in place of the nudge), else the turn ends as
        # cancelled (hook), with nothing salvaged and without a spent nudge.
        # A Stop that came right after the cut is a plain cancel. Returns
        # :retry, or the turn's result.
        def after_cut(iteration, response)
          return canceled(iteration, @cancel_controller.reason) if @cancel_controller.cancelled?

          if @empty_retry.left?
            return :retry if inject_pending_input(iteration)

            @empty_retry.nudge!(@conversation, TurnNote.cut_retry(response.cut[:by], response.cut[:reason]),
                                emit: method(:emit), iteration: iteration, finish_reason: response.finish_reason,
                                thinking_chars: response.reasoning.to_s.length, stopped_by: response.cut[:by])
            return :retry
          end
          @empty_retry.drop_nudge!(@conversation)
          @cancel_controller.cancel!(:hook, response.cut)
          canceled(iteration, :hook)
        end

        # The host's reasoning, kept on the model message as +thinking+ for
        # the web turn view's reload (the whole of it, as the live view
        # shows). Only saved: #assistant_message builds the wire message from
        # content and tool_calls, so it never goes back to the model.
        def with_thinking(message, response)
          reasoning = response.reasoning.to_s
          reasoning.strip.empty? ? message : message.merge(thinking: reasoning)
        end

        # One streamed request. Returns [response, nil], or [reason, partial
        # text] when it was cancelled.
        def generate(iteration)
          window = @window = @loop.context_window(@model_name)
          observe_context(iteration, window)
          retry_generation = @empty_retry.take_sampling!
          emit(type: :generation_started, iteration: iteration, context_window_tokens: window&.tokens,
               context_window_source: window&.source)
          @loop.fire_hook(:before_generation, { type: :before_generation, iteration: iteration })
          streamed = +""
          thought = +""
          response = with_generation do |generation_controller|
            begin
              request(iteration, retry_generation, streamed, thought, generation_controller)
            rescue BadRequest => e
              raise unless thinking_refused?(e)

              # Once per model: asked again without the thinking fields.
              @loop.thinking_refused!(@model_name)
              emit(type: :thinking_refused, iteration: iteration, model: @model_name, level: @loop.thinking, detail: e.detail)
              request(iteration, retry_generation, streamed, thought, generation_controller)
            end
          rescue RequestCancelled
            raise unless generation_controller&.cancelled? && !@cancel_controller.cancelled?

            return cut_response(iteration, thought, generation_controller.detail || {})
          end
          record_context_status(response.usage, window)
          emit(type: :generation_completed, iteration: iteration, content_length: response.text.length,
               thinking_chars: response.reasoning.to_s.length, served_model: response.model,
               requested_model: @model_name, finish_reason: response.finish_reason)
          dump_response(response, iteration)
          @loop.fire_hook(:after_generation, { type: :after_generation, iteration: iteration, response: response.text,
                                               messages: AnswerDisplay.strip_all(@conversation).map(&:dup).freeze })
          [response, nil]
        rescue RequestCancelled => e
          [e.reason, streamed]
        end

        # The request runs under the generation's own controller (the turn
        # controller's child), so a plugin's stop_generation cuts it alone.
        def with_generation(&block)
          return yield(nil) unless @cancel_controller

          @cancel_controller.generation(&block)
        end

        # The empty response of a cut generation: its spinners close as any
        # generation's (finish_reason stopped, stopped_by the bundle); no
        # after_generation (there is no answer to see), and no usage (the
        # stream never sent its last chunk).
        def cut_response(iteration, thought, cut)
          emit(type: :generation_completed, iteration: iteration, content_length: 0, thinking_chars: thought.length,
               requested_model: @model_name, finish_reason: "stopped", stopped_by: cut[:by], stop_reason: cut[:reason])
          response = ChatResponse.new(text: "", reasoning: thought, tool_calls: [], usage: nil, finish_reason: "stopped",
                                      cut: cut)
          [response, nil]
        end

        def request(iteration, retry_generation, streamed, thought, generation_controller)
          @loop.adapter.chat(
            messages: @loop.wire_messages(@conversation), tools: @loop.tool_definitions, model: @model_name,
            cancel_controller: generation_controller || @cancel_controller, session_id: @loop.session_id,
            options: @loop.request_options(retry_generation: retry_generation, model: @model_name),
            on_delta: lambda { |content:, reasoning:, payload:|
              streamed << content
              thought << reasoning
              emit(type: :generation_chunk, iteration: iteration, content: reasoning + content, text: content,
                   thinking: reasoning, payload: payload)
            },
            on_retry: ->(**retry_event) { emit({ type: :generation_retrying, iteration: iteration }.merge(retry_event)) }
          )
        end

        # A 400 about reasoning, for a request that carried thinking fields
        # (not a missing-tools, image or context error).
        def thinking_refused?(error)
          error.reasoning_refused? && !error.is_a?(VisionUnsupported) && !error.tools_unsupported? &&
            !error.context_overflow? && !@loop.thinking_fields(@model_name).empty?
        end

        # Before a request, as the native loop: estimate how full the window
        # is (the server's last count plus what the turn appended since),
        # emit :context_status on a bucket change, and put the model's own
        # line on the tail on a rise that asks it for a change. The estimate
        # counts the conversation's text and tool calls, not the tool
        # schemas (the server's count does).
        def observe_context(iteration, window)
          return unless window

          @request_image_tokens = ImagePlan.estimated_tokens(@conversation)
          event = @context.observe(prompt_chars, iteration_index: iteration - 1, window: window,
                                                 image_tokens: @request_image_tokens)
          emit(type: :context_status, iteration: iteration, **event) if event
          if (line = @context.take_guidance)
            @conversation << line
          end
          @request_chars = prompt_chars
        end

        # The conversation's text as the request carries it: contents (a
        # parts list's text parts) and the tool calls' names and arguments.
        def prompt_chars
          @conversation.sum do |entry|
            content = entry[:content]
            chars = if content.is_a?(Array)
                      content.sum { |part| part.is_a?(Hash) ? (part[:text] || part["text"]).to_s.length : 0 }
                    else
                      content.to_s.length
                    end
            chars + Array(entry[:tool_calls]).sum { |call| call[:name].to_s.length + call[:arguments].to_json.length }
          end
        end

        # The server's counts for this request (prompt + answer): the status
        # line's value, and where the next estimate starts. Without them the
        # estimate stays.
        def record_context_status(usage, window)
          return unless usage.source == :server

          counts = @context.capture({ "usage" => { "prompt_tokens" => usage.prompt_tokens,
                                                   "completion_tokens" => usage.completion_tokens } })
          @context.generation_done(counts, prompt_chars: @request_chars.to_i, image_tokens: @request_image_tokens.to_i,
                                           window: window)
        end

        # The model's answer at debug level, as the native loop dumps its
        # raw response (the tool calls and results come through the kernel's
        # dispatch dumps).
        def dump_response(response, iteration)
          return unless Log.level?(:debug)

          thinking = response.reasoning.to_s
          text = thinking.empty? ? response.text.to_s : "<thinking>\n#{thinking}\n</thinking>\n#{response.text}"
          calls = Array(response.tool_calls).map(&:name)
          Log.debug(:model, "response", payload: text, model: @model_name, iteration: iteration,
                                        served_model: response.model, tool_calls: calls.empty? ? nil : calls.join(","))
        end

        # Each call's result goes on the conversation as it finishes, paired
        # with its call (ToolResponse.single: the capped output).
        def dispatch(tool_calls, iteration, cap)
          calls = tool_calls.map { |tool_call| NativeToolNormalizer.normalize(tool_call) }
          runs = ToolResponse.run_batch(@loop.tool_runner, calls, iteration: iteration, emit: method(:emit),
                                                                  on_stream_event: @on_stream_event, cap: cap) do |run, index|
            @conversation << ToolResponse.single(run, tool_call_id: tool_calls[index].id)
          end
          @tool_activity.concat(ToolResponse.activities(runs))
        end

        # Queued input at an iteration boundary (Steer.inject!). Returns true
        # when there was any.
        def inject_pending_input(iteration, answer: nil)
          Steer.inject!(@conversation, @pending_input, iteration: iteration, emit: method(:emit),
                                                       cancel_controller: @cancel_controller, answer: answer)
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
                          cancellation_reason: reason, tool_activity: @tool_activity, usage: usage,
                          context_status: @context.display)
        end

        def result(text, exhausted:)
          ModelResult.new(text: text, provider: :chat, conversation: @loop.plain(@conversation), exhausted: exhausted,
                          tool_activity: @tool_activity, usage: usage, empty_answer: text == EMPTY_ANSWER,
                          context_status: @context.display)
        end

        def usage
          @usage.usage(prompt_text: @prompt_text, extra_prompt_tokens: @image_tokens)
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
