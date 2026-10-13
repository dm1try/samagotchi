# frozen_string_literal: true

require_relative "../iteration_limit"
require "json"
require_relative "backend"
require_relative "model_result"
require_relative "errors"
require_relative "usage"
require_relative "openai_chat"
require_relative "native_tool_normalizer"
require_relative "stream_drops"
require_relative "../kernel_loop"
require_relative "../answer_display"
require_relative "../answer_refs"
require_relative "../cut_policy"
require_relative "../context_status"
require_relative "../context_window"
require_relative "../context_note"
require_relative "../tool_runner"
require_relative "../tool_response"
require_relative "../tool_ids"
require_relative "../tool_declarations"
require_relative "../vision_context"
require_relative "../log"
require_relative "../empty_answer_retry"
require_relative "../steer"
require_relative "../reasoning_history"
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
      include LLM::StreamDrops

      # The line after an answer an OpenAI-compatible host's content filter
      # cut (finish_reason content_filter with text): kept, not asked again.
      FILTERED_MARK = "[cut off by the provider's content filter]"

      attr_accessor :adapter
      # The session every request is for; Engine sets it with the adapter.
      # Goes out as a Session-Id header (OpenAIChat#chat).
      attr_accessor :session_id

      # @param kernel [KernelLoop] tool dispatch, thought stripping, hooks
      # @param adapter [OpenAIChat, nil] the host to talk to; Engine sets it
      #   per turn for the effective model's host
      # @param stable_length [#call, nil] text → the length of the system
      #   prompt's part every session shares (SystemPrompt#stable_length), or nil
      # @param sleeper [#call, nil] waits the given seconds before a dropped
      #   stream's step is asked again (specs pass one that doesn't sleep)
      def initialize(kernel:, adapter: nil, stable_length: nil, sleeper: nil)
        @kernel = kernel
        @adapter = adapter
        @stable_length = stable_length
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      end

      def provider = :chat

      # +reasoning_since+ (ModelBackend#complete): the resumed run's start,
      # the Run's own start then (Run#initialize, #reasoning_boundary).
      def complete(messages:, max_iterations: IterationLimit::DEFAULT, on_stream_event: nil, cancel_controller: nil,
                   model_name: nil, max_tool_output_chars: nil, pending_input: nil, reasoning_since: nil)
        raise ArgumentError, "ChatLoop has no adapter" unless @adapter

        conversation = Array(messages).map(&:dup)
        Run.new(self, conversation, on_stream_event, cancel_controller, model_name, pending_input, start: reasoning_since)
           .call(max_iterations: max_iterations || 1, cap: KernelLoop.resolve_output_char_cap(max_tool_output_chars))
      rescue StandardError => e
        FailedTurn.attach(e, conversation && plain(conversation))
        raise
      end

      # Tool definitions for the request: the schemas the native prompts are
      # rendered from (the kernel's registry, the tools the turn's LLM
      # context layers offer), with the chat-only enums and closed
      # parameters.
      def tool_definitions
        ToolDeclarations.chat_schemas(tools.schemas(layers: llm_context_layers)).map do |schema|
          { type: "function", function: schema.slice(:name, :description, :parameters) }
        end
      end

      # The kernel's tools.
      def tools = @kernel.tools

      # The turn's LLM context layers (KernelLoop#llm_context_layers).
      def llm_context_layers = @kernel.llm_context_layers

      # The turn's LLM context strategy (LLMContextStrategy::Resolved), nil
      # when none was resolved.
      def llm_context = @kernel.turn_settings&.llm_context

      # KernelLoop#reprefilled_tokens, the kernel's request history.
      def reprefilled_tokens(model, **) = @kernel.reprefilled_tokens(model, **)

      # The kernel's LLMContextView, the turn's strategy.
      def llm_context_view = @kernel.llm_context_view

      # The strategy's own edits before a request and at turn end
      # (KernelLoop#apply_llm_context!).
      def apply_llm_context!(conversation, **) = @kernel.apply_llm_context!(conversation, **)

      # The running turn, for forget_outputs (KernelLoop#llm_context_turn).
      def llm_context_turn=(turn)
        @kernel.llm_context_turn = turn
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
      #
      # A model turn carries its saved reasoning as reasoning_content when
      # +reasoning+ (a ReasoningHistory level; the turn's by default) says
      # so: under turn the running turn's only (#reasoning_boundary, with
      # +since+ where the Run's reasoning starts; a steer it merged doesn't
      # move that), under all every one.
      #
      # The conversation goes through the kernel's LLMContextView first,
      # as the native prompt does (it keeps every entry in place).
      def wire_messages(conversation, since: nil, reasoning: reasoning_history)
        conversation = llm_context_view.messages(conversation)
        paired = paired_call_ids(conversation)
        boundary = reasoning_boundary(conversation, since: since, level: reasoning)
        # The last reply with tool calls keeps its thinking blocks past the
        # boundary: a run stopped between steps (Stop, the step limit) left
        # its tool_use last, and Messages wants the thinking before it.
        last_calls = conversation.rindex { |entry| entry[:role].to_s == "model" }
        last_calls = nil unless last_calls && !Array(conversation[last_calls][:tool_calls]).empty?
        plan = ImagePlan.new(conversation, vision)
        tool_images = []
        wire = []
        conversation.each_with_index do |entry, index|
          items = plan.items(entry, index)
          case entry[:role].to_s
          when "system"
            wire << system_message(entry, index)
          when "user"
            # A steer or merged input (always a String) goes with its header.
            content = Steer.header(entry) ? Steer.wire_text(entry, entry[:content].to_s) : entry[:content]
            wire << { role: "user", content: parts(content, items) }
          when "model"
            message = assistant_message(entry, paired)
            message[:reasoning_content] = entry[:thinking] if boundary && index >= boundary && thought?(entry)
            blocks = replay_blocks(entry, paired, keep_thinking: (boundary && index >= boundary) || index == last_calls)
            message[:anthropic_content] = blocks if blocks
            wire << message
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

      # The head system prompt says where its stable part ends
      # (`cache_split:`, a character offset): the adapter puts a remote
      # Claude model's cache breakpoint there (PromptCache) and drops it
      # for every other request.
      def system_message(entry, index)
        text = entry[:content].to_s
        split = index.zero? && @stable_length&.call(text)
        split ? { role: "system", content: text, cache_split: split } : { role: "system", content: text }
      end

      TOOL_IMAGES_TEXT = "[images from tool results]"

      # The first index whose model entries carry their reasoning (nil:
      # none do) under +level+. Under turn: +since+ when given, where a
      # Run's reasoning starts (ReasoningHistory.run_start, the native
      # loop's rule: an entry the run merged -- a person's line, a plugin's
      # steer, a Continue's text -- keeps the reasoning before it, so the
      # request after it extends the one before; a continue turn -- a
      # reminder, a context wake, a delegate report's wake -- starts a Run
      # of its own and sends none of the run before it). Without +since+,
      # past the last query (a user message or an entry that starts a turn,
      # turn_start).
      # @return [Integer, nil]
      def reasoning_boundary(conversation, since: nil, level: reasoning_history)
        case level
        when :all then 0
        when :turn
          return since if since

          query = conversation.rindex { |entry| entry[:role].to_s == "user" || entry[:turn_start] == true }
          query ? query + 1 : 0
        end
      end

      # The reasoning +conversation+'s wire messages carry from +since+ on
      # (#reasoning_boundary), in characters.
      def reasoning_chars(conversation, since: nil, reasoning: reasoning_history)
        boundary = reasoning_boundary(conversation, since: since, level: reasoning) or return 0
        conversation.drop(boundary).sum { |entry| entry[:role].to_s == "model" && thought?(entry) ? entry[:thinking].length : 0 }
      end

      # The turn's ReasoningHistory level (the kernel's turn_settings); drop
      # without settings, and for a +model+ whose host refused it
      # (#reasoning_history_refused!). An adapter that sends its blocks back
      # (#replays_content?) is floored at turn: the running run's thinking
      # blocks always go back (a tool loop with thinking needs the last
      # assistant turn's), whatever the level says.
      def reasoning_history(model = nil)
        level = model && @reasoning_history_refused&.include?(model) ? :drop : @kernel.turn_settings&.reasoning_history
        level ||= :drop
        level == :drop && replays_content? ? :turn : level
      end

      # Whether the adapter sends a model entry's saved blocks back verbatim
      # (AnthropicMessages); the OpenAI wire doesn't.
      def replays_content? = @adapter.respond_to?(:replays_content?) && @adapter.replays_content?

      # The host refused +model+'s reasoning sent back: send none from now on
      # (this worker's lifetime, as #thinking_refused!).
      def reasoning_history_refused!(model)
        (@reasoning_history_refused ||= Set.new) << model
      end

      # The turn's VisionContext (the Engine sets the kernel's
      # turn_settings), or nil.
      def vision = @kernel.turn_settings.vision

      # The turn's configured price (the kernel's turn_settings), or nil.
      def price = (@kernel.turn_settings&.price if @kernel.respond_to?(:turn_settings))

      # The turn's request parameters (the kernel's turn_settings).
      def sampling = @kernel.turn_settings.sampling || {}

      # The turn's thinking level (the kernel's turn_settings).
      def thinking = @kernel.turn_settings.thinking || Thinking::DEFAULT

      # The request fields the thinking level adds, as the adapter's wire
      # takes them (OpenAIChat#thinking_fields: Thinking.chat_fields); none
      # for a model whose host refused them (#thinking_refused!).
      def thinking_fields(model = nil)
        return {} if model && (@thinking_refused ||= Set.new).include?(model)

        adapter.thinking_fields(thinking)
      end

      # The host refused +model+'s thinking fields: leave them out from now on.
      def thinking_refused!(model)
        (@thinking_refused ||= Set.new) << model
      end

      # One generation's options: default.max_tokens as max_tokens (the
      # adapter's own default, OpenRouter's, otherwise), the thinking fields
      # under the sampling (a sampling key wins, chat_template_kwargs merges
      # per sub-key), the empty-answer retry's temperature on top, then every
      # null dropped at any depth (a sampling null means "don't send it").
      # A +model+ whose host refused a sampling field (#sampling_refused!)
      # gets none of SAMPLING_KEYS.
      def request_options(retry_generation: false, model: nil)
        max_tokens = Samagotchi::Config.max_tokens
        options = deep_merge(thinking_fields(model), sampling)
        options = { max_tokens: max_tokens }.merge(options) if max_tokens
        options = EmptyAnswerRetry.sampling(options) if retry_generation
        options = options.except(*SAMPLING_KEYS) if model && @sampling_refused&.include?(model)
        deep_compact(options)
      end

      # The fields a sampling refusal (BadRequest#sampling_refused?) drops.
      SAMPLING_KEYS = %i[temperature top_p top_k].freeze

      # The host refused a sampling field for +model+: send none of
      # SAMPLING_KEYS from now on (this worker's lifetime, as #thinking_refused!).
      def sampling_refused!(model)
        (@sampling_refused ||= Set.new) << model
      end

      def strip_model_thought(text) = @kernel.strip_model_thought(text)

      def tool_runner
        @tool_runner ||= ToolRunner.new(@kernel)
      end

      # The window for +model+: the kernel's client probes the server it
      # points at (Engine keeps it on the effective model's host; a local
      # llama.cpp answers /props), then the host's model list, the model's
      # or host's window_tokens, config, env and the default. A remote
      # provider has no /props to probe.
      def context_window(model)
        client = @adapter.remote? ? nil : @kernel.client
        ContextWindow.resolve(client: client, model: model, adapter: @adapter,
                              setting: (@kernel.turn_settings&.window_setting if @kernel.respond_to?(:turn_settings)))
      rescue StandardError
        nil
      end

      # A hook failing must not break the turn (as in ToolRunner).
      def fire_hook(name, event)
        @kernel.hooks&.fire(name, event)
      rescue StandardError
        nil
      end

      # The shape the engine persists: role and content (parts stay an
      # Array), plus a model turn's tool_calls and thinking (the host's
      # reasoning, sent back as #wire_messages says), a result's tool_call_id, the image
      # refs of a user message or a tool result, a prompt's turn_id (Engine,
      # never sent) and a wake turn's report's turn_start (Steer, never sent), and a plugin tool result's tool_params and tool_labels
      # (the live row's params line and label, never sent back), an
      # edit/write result's tool_diffs (never sent), an empty-answer
      # note's marker (TurnNote.empty, never sent), and an answer's display
      # and display_refs (AnswerDisplay, AnswerRefs; never sent).
      def plain(conversation)
        conversation.map do |entry|
          content = entry[:content].is_a?(Array) ? entry[:content] : entry[:content].to_s
          message = { role: entry[:role], content: content }
          message[:tool_calls] = entry[:tool_calls] if entry[:tool_calls].is_a?(Array) && !entry[:tool_calls].empty?
          message[:tool_call_id] = entry[:tool_call_id] if entry[:tool_call_id]
          message[:images] = entry[:images] if entry[:images].is_a?(Array) && !entry[:images].empty?
          message[:turn_id] = entry[:turn_id] if entry[:turn_id]
          message[:turn_start] = true if entry[:turn_start] == true
          message[:thinking] = entry[:thinking] if entry[:thinking].is_a?(String) && !entry[:thinking].empty?
          message[:anthropic_content] = entry[:anthropic_content] if entry[:anthropic_content].is_a?(Array)
          ToolResponse::SAVED_KEYS.each { |key| message[key] = entry[key] if entry[key] }
          message[TurnNote::RETRY_NUDGE] = true if TurnNote.retry_nudge?(entry)
          marker = TurnNote.empty_answer(entry)
          message[TurnNote::EMPTY_ANSWER] = marker if marker
          message[AnswerDisplay::KEY] = entry[AnswerDisplay::KEY] if entry[AnswerDisplay::KEY]
          message[AnswerRefs::KEY] = entry[AnswerRefs::KEY] if entry[AnswerRefs::KEY]
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

      def thought?(entry) = entry[:thinking].is_a?(String) && !entry[:thinking].strip.empty?

      THINKING_BLOCKS = %w[thinking redacted_thinking].freeze

      # A model entry's saved blocks (anthropic_content) to send back
      # verbatim, for an adapter that replays them: nil when there are none,
      # for an interrupted entry (its partial blocks have no signature), and
      # for one with unpaired calls (it goes as flattened text: a tool_use
      # without its tool_result would fail every later request). Before the
      # reasoning boundary (+keep_thinking+ false) the thinking blocks are
      # left out, which removes them only from the front of the history.
      def replay_blocks(entry, paired, keep_thinking:)
        blocks = entry[:anthropic_content]
        return nil unless replays_content? && blocks.is_a?(Array) && !blocks.empty? && !entry[:interrupted]
        return nil unless Array(entry[:tool_calls]).all? { |call| paired.include?(call[:id]) }

        blocks = blocks.reject { |block| block.is_a?(Hash) && THINKING_BLOCKS.include?((block["type"] || block[:type]).to_s) } unless keep_thinking
        blocks.empty? ? nil : blocks
      end

      def scrub(text)
        text.encoding == Encoding::UTF_8 && !text.valid_encoding? ? text.scrub("?") : text
      end

      # One turn's state: the conversation, the stream sink and tool
      # activity.
      class Run
        # Messages' refusal; OpenAI's content filter, a refusal only when
        # it left no text (else the text stays, marked FILTERED_MARK).
        REFUSAL = "refusal"
        FILTERED = "content_filter"

        # +start+: where the run a step-limit Continue resumes started (nil:
        # this run starts at the conversation's end).
        def initialize(loop, conversation, on_stream_event, cancel_controller, model_name, pending_input, start: nil)
          @loop = loop
          @conversation = conversation
          @on_stream_event = on_stream_event
          @cancel_controller = cancel_controller
          @model_name = model_name
          @pending_input = pending_input
          # Where the reasoning this run sends back starts
          # (ChatLoop#reasoning_boundary): its own replies', a resumed run's
          # too, fixed for the run; a steer it merges doesn't move it.
          @reasoning_start = ReasoningHistory.run_start(conversation, start || conversation.length)
          @tool_activity = []
          @empty_retry = EmptyAnswerRetry.new
          # The empty generations, never saved: the UIs draw the turn's
          # steps from them (ModelResult#empty_steps).
          @empty_steps = []
          @context = ContextStatus.new(conversation: conversation, llm_context: loop.llm_context)
          loop.llm_context_turn = LLMContextForget::Turn.new(conversation: conversation, context: @context,
                                                             emit: method(:emit))
        end

        def call(max_iterations:, cap:)
          last_text = ""
          exhausted = true
          max_iterations.times do |index|
            iteration = index + 1
            return canceled(iteration, @cancel_controller.reason) if @cancel_controller&.cancelled?

            inject_pending_input(iteration)
            response, partial, thought = generate(iteration)
            return canceled(iteration, response, partial, thought) if partial

            if response.cut
              outcome = after_cut(iteration, response)
              next if outcome == :retry

              return outcome
            end

            last_text = @loop.strip_model_thought(response.text)
            # A provider's refusal (or its content filter) ends the turn here:
            # tool calls that came with it are not run.
            @refusal = refusal_of(response, last_text)
            stopped = @refusal || response.finish_reason.to_s == FILTERED
            if response.tool_calls.empty? || stopped
              # A refusal is no answer, never asked again; text it streamed
              # before is not kept as one. A filtered answer's text stays,
              # marked as cut by the filter.
              last_text = "" if @refusal
              last_text = "#{last_text}\n#{FILTERED_MARK}" if !@refusal && response.finish_reason.to_s == FILTERED
              # Only whitespace is no answer either (as in the native loop).
              empty = last_text.strip.empty?
              # Kept before a merge too: the model answers the merged line
              # knowing what it just said.
              @conversation << with_thinking({ role: "model", content: last_text }, response) unless empty
              retry_empty = empty && !stopped &&
                            @empty_retry.retry_empty?(iteration: iteration, cancelled: @cancel_controller&.cancelled?,
                                                      finish_reason: response.finish_reason,
                                                      used_tokens: response.usage&.total_tokens, window_tokens: @window&.tokens)
              # An empty answer that will be retried is no answer site: a
              # plugin's steer joins the retry instead of being dropped, and
              # queued input (a user's line, a steer) goes in place of the nudge.
              next if inject_pending_input(iteration, answer: retry_empty ? nil : last_text)

              # An empty answer (content "" + stop, seen from a remote host)
              # ends the turn with no text: the UIs show their notice.
              @empty_steps << with_thinking({ role: "model", content: "" }, response) if empty
              next if retry_empty && nudge_empty_answer(iteration, response)

              last_text = "" if empty
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

        # A provider's refusal as ModelResult#refusal ({category:} when its
        # stop_details name one): finish reason refusal, or content_filter
        # with no visible +text+.
        def refusal_of(response, text)
          reason = response.finish_reason.to_s
          return nil unless reason == REFUSAL || (reason == FILTERED && text.strip.empty?)

          details = response.stop_details
          category = details["category"] || details[:category] if details.is_a?(Hash)
          category.to_s.strip.empty? ? {} : { category: category.to_s }
        end

        # The hidden nudge before the next generation (EmptyAnswerRetry),
        # which runs at the retry temperature. Returns true.
        def nudge_empty_answer(iteration, response)
          @empty_retry.nudge!(@conversation, TurnNote.empty_retry,
                              emit: method(:emit), iteration: iteration, finish_reason: response.finish_reason,
                              thinking_chars: response.reasoning.to_s.length)
        end

        # A cut generation (CutPolicy): a Stop after it ends the turn as
        # any cancel, the turn going on is :retry, the hook ending is the
        # turn's result.
        def after_cut(iteration, response)
          outcome = CutPolicy.decide(cut: response.cut, cancel_controller: @cancel_controller, empty_retry: @empty_retry,
                                     conversation: @conversation, iteration: iteration, emit: method(:emit),
                                     inject: -> { inject_pending_input(iteration) },
                                     finish_reason: response.finish_reason,
                                     thinking_chars: response.reasoning.to_s.length)
          return canceled(iteration, @cancel_controller.reason) if outcome.stopped?
          return :retry if outcome.again?

          canceled(iteration, :hook)
        end

        # The host's reasoning, kept on the model message as +thinking+ for
        # the web turn view's reload (the whole of it, as the live view
        # shows), and sent back to the model as ChatLoop#wire_messages says
        # (reasoning_history). A wire that sends its blocks back keeps them
        # as +anthropic_content+ (ChatResponse#provider_content: string
        # keys, as received, so a resumed session sends the same bytes).
        def with_thinking(message, response)
          reasoning = response.reasoning.to_s
          message = message.merge(thinking: reasoning) unless reasoning.strip.empty?
          blocks = response.provider_content
          blocks.is_a?(Array) && !blocks.empty? ? message.merge(anthropic_content: blocks) : message
        end

        # One streamed request. Returns [response, nil], or [reason, partial
        # text] when it was cancelled.
        def generate(iteration)
          # The strategy's edits the apply rule lets through first (stale):
          # this request sends them.
          @loop.apply_llm_context!(@conversation, context: @context, emit: method(:emit))
          window = @window = @loop.context_window(@model_name)
          observe_context(iteration, window)
          retry_generation = @empty_retry.take_sampling!
          emit(type: :generation_started, iteration: iteration, context_window_tokens: window&.tokens,
               context_window_source: window&.source, price: @loop.price&.to_h)
          @loop.fire_hook(:before_generation, { type: :before_generation, iteration: iteration })
          streamed = +""
          thought = +""
          generation_controller = nil
          response = with_generation do |controller|
            generation_controller = controller
            # One count for the step: an ask-again without reasoning or
            # thinking fields doesn't get drops of its own.
            drops = LLM::StreamDrops::DropCount.new(0, 0)
            ask = -> { request_with_drops(iteration, retry_generation, streamed, thought, drops, controller) }
            begin
              ask.call
            rescue BadRequest => e
              # A wire that replays its blocks sends them under the turn
              # floor anyway: asking again without reasoning would resend
              # the same body.
              if e.sampling_refused? && sampling_sent?(retry_generation) then without_sampling(iteration, e, ask)
              elsif refused?(e) && reasoning_sent? && !@loop.replays_content? then without_reasoning(iteration, e, ask)
              elsif thinking_refused?(e) then without_thinking(iteration, e, ask)
              else raise
              end
            end
          rescue RequestCancelled
            raise unless generation_controller&.cancelled? && !@cancel_controller.cancelled?

            return cut_response(iteration, thought, generation_controller.detail || {})
          end
          record_context_status(response.usage, window)
          emit(type: :generation_completed, iteration: iteration, content_length: response.text.length,
               thinking_chars: response.reasoning.to_s.length, served_model: response.model,
               served_provider: response.provider, requested_model: @model_name, finish_reason: response.finish_reason,
               **(response.usage&.cache_fields || {}), **reprefill_field(response.usage))
          dump_response(response, iteration)
          @loop.fire_hook(:after_generation, { type: :after_generation, iteration: iteration, response: response.text,
                                               messages: AnswerDisplay.strip_all(@conversation).map(&:dup).freeze })
          [response, nil]
        rescue RequestCancelled => e
          [e.reason, streamed, thought]
        end

        # The request's re-prefilled tokens (KernelLoop#reprefilled_tokens).
        def reprefill_field(usage)
          return {} unless usage&.source == :server

          tokens = @loop.reprefilled_tokens(@model_name, prompt: usage.prompt_tokens, cached: usage.cached_tokens)
          tokens ? { reprefill_tokens: tokens } : {}
        end

        # The request runs under the generation's own controller (the turn
        # controller's child), so a plugin's stop_generation cuts it alone.
        def with_generation(&)
          return yield(nil) unless @cancel_controller

          @cancel_controller.generation(&)
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

        def request(iteration, retry_generation, streamed, thought, generation_controller, streamed_any = nil)
          @loop.adapter.chat(
            messages: @loop.wire_messages(@conversation, since: @reasoning_start, reasoning: reasoning_level), tools: @loop.tool_definitions, model: @model_name,
            cancel_controller: generation_controller || @cancel_controller, session_id: @loop.session_id,
            options: @loop.request_options(retry_generation: retry_generation, model: @model_name),
            on_delta: lambda { |content:, reasoning:, payload:|
              streamed << content
              thought << reasoning
              event = { type: :generation_chunk, iteration: iteration, content: reasoning + content, text: content,
                        thinking: reasoning, payload: payload }
              # A tool call streaming: a steer doesn't cut it (Engine#cut_for_steer).
              tool_call = @loop.adapter.tool_call_delta?(payload)
              event[:tool_call] = true if tool_call
              streamed_any&.call if !content.to_s.empty? || !reasoning.to_s.empty? || tool_call
              emit(event)
            },
            on_retry: ->(**retry_event) { emit({ type: :generation_retrying, iteration: iteration }.merge(retry_event)) }
          )
        end

        # A dropped stream (LLM::HTTP raises RetryExhausted once a stream
        # that already showed something fails, where a retry would repeat
        # output) is asked again here, from the same conversation, up to
        # MAX_STREAM_DROPS times per step (fewer under a smaller retry.max;
        # none with 0), after the transport's backoff: the partial reply is
        # dropped and the step restarts. A refusal or a first-token timeout
        # fails as before, and a cancel (before or during the wait) never
        # retries. +count+ (a DropCount) carries on across calls for one
        # step.
        def request_with_drops(iteration, retry_generation, streamed, thought, count, generation_controller)
          streamed_any = false
          request(iteration, retry_generation, streamed, thought, generation_controller, -> { streamed_any = true })
        rescue RetryExhausted => e
          # A cancel that landed as the stream dropped ends the turn canceled,
          # not failed, whatever the drop's count.
          cancelled = [@cancel_controller, generation_controller].compact.find(&:cancelled?)
          raise RequestCancelled, cancelled.reason if cancelled

          count.requests += e.attempts.to_i
          limit = @loop.stream_drop_limit(LLM::StreamDrops::MAX_STREAM_DROPS)
          if count.drops >= limit || !streamed_any
            raise if count.requests == e.attempts.to_i

            raise RetryExhausted.new(attempts: count.requests, last_error: e.last_error, label: e.host)
          end

          count.drops += 1
          attempt = count.drops
          streamed.clear
          thought.clear
          delay = @loop.generation_retry_delay(attempt)
          # restarted: the step's streamed chunks so far are void (the UIs
          # and the Bridge's TurnAccumulator drop them).
          emit(type: :generation_retrying, iteration: iteration, attempt: attempt, max_retries: limit,
               next_delay: delay, error_class: e.class.name, error_message: e.message, status: nil, restarted: true)
          @loop.wait_retry(delay, @cancel_controller, generation_controller)
          retry
        rescue ProviderError => e
          # Another failure (a 503, a refusal) after earlier requests this
          # step: its count takes theirs in.
          count.requests += e.attempts.to_i
          e.attempts = count.requests
          raise
        end

        # A 400 about reasoning (not a missing-tools, image or context error).
        def refused?(error)
          error.reasoning_refused? && !error.is_a?(VisionUnsupported) && !error.tools_unsupported? &&
            !error.context_overflow?
        end

        # #refused?, for a request that carried thinking fields.
        def thinking_refused?(error) = refused?(error) && !@loop.thinking_fields(@model_name).empty?

        # Whether this step's request sends reasoning back.
        def reasoning_sent?
          !@without_reasoning && @loop.reasoning_chars(@conversation, since: @reasoning_start, reasoning: reasoning_level).positive?
        end

        # The level this step's request sends reasoning back under: none
        # while it is asked again without (#without_reasoning).
        def reasoning_level = @without_reasoning ? :drop : @loop.reasoning_history(@model_name)

        # The host refused a request that sent reasoning back: ask the step
        # again without it. When that goes through, the model sends none from
        # now on. When it is refused too, the thinking fields may be what the
        # host refuses: #without_thinking asks a third time (still without
        # reasoning; a later step sends it again, so a host that refuses
        # only the thinking fields keeps it).
        def without_reasoning(iteration, error, ask)
          @without_reasoning = true
          response = begin
            ask.call
          rescue BadRequest => e
            raise unless thinking_refused?(e)

            return without_thinking(iteration, e, ask)
          end
          @loop.reasoning_history_refused!(@model_name)
          emit(type: :reasoning_history_refused, iteration: iteration, model: @model_name,
               level: @loop.reasoning_history, detail: error.detail)
          response
        ensure
          @without_reasoning = false
        end

        # Whether this step's request sends a sampling field.
        def sampling_sent?(retry_generation)
          options = @loop.request_options(retry_generation: retry_generation, model: @model_name)
          SAMPLING_KEYS.any? { |key| options.key?(key) }
        end

        # Once per model: asked again without the sampling fields (the
        # thinking fields stay: an effort level with the empty-answer
        # retry's temperature keeps thinking on).
        def without_sampling(iteration, error, ask)
          @loop.sampling_refused!(@model_name)
          emit(type: :sampling_refused, iteration: iteration, model: @model_name, detail: error.detail)
          ask.call
        end

        # Once per model: asked again without the thinking fields.
        def without_thinking(iteration, error, ask)
          @loop.thinking_refused!(@model_name)
          emit(type: :thinking_refused, iteration: iteration, model: @model_name, level: @loop.thinking, detail: error.detail)
          ask.call
        end

        # Before a request, as the native loop: estimate how full the window
        # is (the server's last count plus what the turn appended since),
        # emit :context_status on every request (observe returns the estimate
        # each time it is enabled), and put the model's own line on the tail
        # on a rise that asks it for a change. The estimate counts the
        # conversation's text and tool calls, not the tool schemas (the
        # server's count does).
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

        # The conversation's text as the request carries it, through the
        # kernel's LLMContextView (a stub counts, not the output it stands
        # for): contents (a parts list's text parts), the tool calls'
        # names and arguments, and the reasoning sent back.
        def prompt_chars
          LLMContextView.chars(@loop.llm_context_view.messages(@conversation)) +
            @loop.reasoning_chars(@conversation, since: @reasoning_start, reasoning: reasoning_level)
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
        # with its call (ToolResponse.single: the capped output), with the
        # next id (ToolIds).
        def dispatch(tool_calls, iteration, cap)
          calls = tool_calls.map { |tool_call| NativeToolNormalizer.normalize(tool_call) }
          runs = ToolResponse.run_batch(@loop.tool_runner, calls, iteration: iteration, emit: method(:emit),
                                                                  on_stream_event: @on_stream_event, cap: cap) do |run, index|
            @conversation << ToolResponse.single(run, tool_call_id: tool_calls[index].id,
                                                      ids: ToolIds.next_ids(@conversation, 1))
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
        # as the native loop's salvage does; the reasoning this generation
        # streamed rides along on the message (with_thinking's key).
        def canceled(iteration, reason, partial = "", thinking = "")
          emit(type: :generation_cancelled, iteration: iteration, reason: reason, stopped_by: @cancel_controller&.stopped_by)
          visible = @loop.strip_model_thought(partial.to_s).strip
          unless visible.empty?
            message = { role: "model", content: "#{visible}\n[interrupted]", interrupted: true }
            thought = thinking.to_s
            message[:thinking] = thought unless thought.strip.empty?
            @conversation << message
          end
          conversation = @loop.plain(@conversation)
          conversation.last[:interrupted] = true unless visible.empty?
          ModelResult.new(text: "", conversation: conversation, canceled: true,
                          cancellation_reason: reason, tool_activity: @tool_activity,
                          context_status: @context.display)
        end

        def result(text, exhausted:)
          # The model answered: the staged edits reach the session now (a
          # turn that ran out of steps is mid-task; they wait).
          @loop.apply_llm_context!(@conversation, moment: :turn_end, emit: method(:emit)) unless exhausted
          ModelResult.new(text: text, conversation: @loop.plain(@conversation), exhausted: exhausted,
                          tool_activity: @tool_activity, empty_steps: @empty_steps, empty_retries: @empty_retry.attempts,
                          context_status: @context.display, refusal: (@refusal unless exhausted))
        end

        def emit(event)
          @on_stream_event&.call(event)
        rescue StandardError
          nil
        end
      end
      private_constant :Run
    end
  end
end
