# frozen_string_literal: true

require_relative "model_profile"
require_relative "tool_call_parser"
require_relative "config"
require_relative "context_status"
require_relative "context_window"
require_relative "prompt"
require_relative "prompt_literal_guard"
require_relative "client"
require_relative "llm/errors"
require_relative "log"
require_relative "empty_answer_retry"
require_relative "thinking"
require_relative "hooks"
require_relative "pending_input_queue"
require_relative "steer"
require_relative "thought_stream_splitter"
require_relative "tools/builtins"
require_relative "muted_memories"
require_relative "tool_activity"
require_relative "tool_runner"
require_relative "answer_display"

module Samagotchi
  # The KernelLoop drives the model ↔ tool interaction cycle.
  #
  # Flow:
  #   1. Format the conversation using the active profile and call llama.cpp.
  #   2. Parse the response for tool-call blocks in the profile's format.
  #   3. Dispatch each tool call, collect results.
  #   4. Inject results as a tool_response message and repeat from step 1.
  #   5. Stop when the model emits no tool calls or max_iterations is reached.
  #
  # Supports multiple model profiles:
  #   - Gemma 4: <|tool_call>call:NAME{params}<tool_call|>
  #   - Qwen 3.6: <tool_call><function=NAME><parameter=KEY>VALUE</parameter></function></tool_call>
  class KernelLoop
    Result = Struct.new(:output, :conversation, :exhausted, :pending_tool_calls, :tool_activity, :canceled, :cancellation_reason, :context_status, keyword_init: true) do
      def exhausted?
        exhausted
      end

      def pending_tool_calls?
        pending_tool_calls
      end

      def resumable?
        exhausted? && pending_tool_calls?
      end

      def canceled?
        canceled
      end
    end

    # The built-in tool classes (Tools::Builtins registers them).
    TOOLS = Tools::Builtins::CLASSES

    # What a tool handler (call, kctx) gets from the kernel: the reminder
    # store, the peers, the model key, and the memory read and ask-user
    # flows that need its state.
    class ToolContext
      def initialize(kernel)
        @kernel = kernel
      end

      def reminder_store = @kernel.reminder_store
      def peers = @kernel.peers
      def model_key = @kernel.model_key
      def muted_memory_read(call) = @kernel.__send__(:muted_memory_read, Tools::MemoryRead, call)
      def ask_user_question(call) = @kernel.__send__(:handle_ask_user_question, call)
    end

    DEFAULT_MAX_TOOL_OUTPUT_CHARS = 10_000
    QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_LIMIT = 2
    QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_PROMPT = "Continue the previous assistant message by finishing the open <tool_call> XML block. Output only the remaining XML needed to complete the tool call."

    # @param tools [Tools::Registry, nil] the tools calls dispatch to (the
    #   Engine's; nil: the built-ins alone)
    def initialize(client: nil, profile: nil, model_name: nil, no_interrupt: false, hooks: nil, reminder_store: nil, model_key: nil,
                   tools: nil)
      @client = client || Client.new
      @tools = tools || Tools::Builtins.default
      @no_interrupt = no_interrupt
      resolved_model_name = ModelProfile.required_model_name(model_name)
      # The resolved model id actually used for this run (per-run override wins
      # over the config alias); on every debug dump so we can see exactly
      # which model each request went to. The Engine sets it per turn too:
      # the chat loop dispatches tools here without going through #run.
      @current_model_name = resolved_model_name
      @profile = profile ? ModelProfile.normalize(profile) : ModelProfile.from_model_name(resolved_model_name)
      # Where @profile came from, as /stats shows it (a Resolution's label
      # once the Engine resolves one, see #use_profile!).
      @profile_source = profile ? "given" : "name"
      @hooks = hooks
      @reminder_store = reminder_store
      @model_key = model_key
    end

    # @return [ReminderStore, nil] the reminder store for inspection (used by
    #   Engine to share the same store with the KernelLoop when TerminalUI
    #   creates both).
    attr_reader :reminder_store

    # @return [ModelProfile] the active prompt profile
    attr_reader :profile

    # @return [Samagotchi::Hooks::Registry, nil] hooks registry shared with Engine.
    #   Engine owns the registry; KernelLoop only fires events. Accessor allows
    #   Engine to propagate its registry to an externally-created kernel (TUI path).
    attr_accessor :hooks
    # @return [Tools::Registry] the tools #dispatch runs. The Engine sets
    #   its own on a kernel built before it (the REPL's), as with hooks.
    attr_accessor :tools
    attr_accessor :client
    attr_accessor :model_key
    attr_accessor :current_model_name
    # @return [Array<String>, nil] the session's muted memories (normalized
    #   names, see MutedMemories); memory_read refuses them. The Engine sets it.
    attr_accessor :muted_memory_names
    # @return [Proc, nil] answers ask_user_question (payload → answer string);
    #   Engine sets it to its blocking request_question.
    attr_accessor :question_handler
    # The Guardrails::Gate ToolRunner asks before each call; the Engine sets
    # it (nil: ToolRunner's own, hooks only).
    attr_accessor :guardrail_gate
    # The turn's VisionContext (images: capability, files, limits), set by
    # the Engine per turn; nil sends no images (placeholders instead).
    attr_accessor :vision
    # The turn's request parameters (SamplingSettings.for), set by the Engine
    # per turn; empty or nil sends none.
    attr_accessor :sampling
    # The turn's thinking level (Thinking.resolve), set by the Engine per
    # turn; its own accessor, since the native path sends @sampling as is.
    attr_accessor :thinking
    # Tools::Peers (or the Engine's live view of it): the session
    # list_sessions and send_note speak for; nil outside a session.
    attr_accessor :peers

    # Run the conversation loop and return the final model response plus
    # resumable conversation state when execution stops at max_iterations.
    #
    # @param messages       [Array<Hash>, Result] conversation so far ({role:, content:})
    #                                           or a previous Result to resume
    # @param max_iterations [Integer]            safety cap on tool-call rounds
    # @param on_stream_event [Proc, nil]         optional callback for generation events
    # @param cancel_controller [CancellationController, nil] optional cancellation source
    # @param model_name [String, nil]            optional per-run model override
    # @param max_tool_output_chars [Integer, nil] per-output char cap for the
    #   :tool_call_completed event's `output:` (nil → max_tool_output_chars)
    # @param pending_input [#call, nil]  optional drain proc returning
    #   Array<String> of user steering messages queued while the turn runs.
    #   Drained at iteration boundaries (llama.cpp's /completion cannot accept
    #   steering mid-stream); drained lines merge into ONE user message appended
    #   at the conversation tail (prefix KV cache preserved) and a
    #   :pending_input_merged stream event is emitted.
    # @return [Result] final visible response with continuation metadata
    def run(messages, max_iterations: 100, on_stream_event: nil, cancel_controller: nil, model_name: nil, max_tool_output_chars: nil, pending_input: nil)
      resolved_model_name = completion_model_name(model_name)
      @current_model_name = resolved_model_name

      conversation = prepare_conversation(messages)
      context = ContextStatus.new(conversation: conversation)
      exhausted = false
      pending_tool_calls = false
      tool_activity = []
      qwen_recovery_attempts = 0
      qwen_partial_tool_call = nil
      empty_retries = 0
      empty_retry_limit = EmptyAnswerRetry.limit
      @retry_generation = false
      stream_splitter = ThoughtStreamSplitter.for_profile(@profile)
      # Qwen with thinking off: an empty thought after the cue, so the model
      # answers at once. Kept in the turn's model messages, so each tool-loop
      # prompt starts with what the server already has cached.
      prefill = Thinking.native(@thinking || Thinking::DEFAULT, @profile).prefill
      partial_assistant_buffer = +""

      effective_max_iterations = @no_interrupt ? 1000 : max_iterations
      effective_max_tool_output_chars = resolve_output_char_cap(max_tool_output_chars)
      effective_max_iterations.times do |iteration_index|
        inject_pending_input!(conversation, pending_input, on_stream_event, iteration_index + 1, cancel_controller)
        prompt, images = Prompt.format_with_images(conversation, profile: @profile, vision: @vision, prefill: prefill)
        image_tokens = images.empty? ? 0 : ImagePlan.estimated_tokens(conversation)
        context_window = ContextWindow.resolve(client: @client, model: resolved_model_name)
        emit_context_status_event(on_stream_event, context, prompt, iteration_index: iteration_index, window: context_window,
                                                                    image_tokens: image_tokens)
        if (line = context.take_guidance)
          # The model's own copy, on the tail (the prompt cache keeps its
          # prefix), then the prompt again with it.
          conversation << line
          prompt, images = Prompt.format_with_images(conversation, profile: @profile, vision: @vision, prefill: prefill)
        end
        emit_stream_event(
          on_stream_event,
          type: :generation_started,
          iteration: iteration_index + 1,
          context_window_tokens: context_window.tokens,
          context_window_source: context_window.source,
          profile: @profile.name,
          profile_source: @profile_source
        )
        served_model = nil
        # This generation's own server counts (the run-long ones in
        # `context` can be an earlier one's).
        generation_usage = nil
        # The thinking this generation streamed, for the log (a stuck
        # thinking generation shows as thinking_chars=N content_length=…).
        streamed_thinking = 0
        # Fire :before_generation hook
        gen_event = { type: :before_generation, iteration: iteration_index + 1 }
        fire_hook(:before_generation, gen_event) if @hooks
        # The request runs under the generation's own controller: a plugin's
        # stop_generation cuts it alone, and the turn goes on (a cut).
        buffer_mark = partial_assistant_buffer.length
        cut = nil
        response = with_generation(cancel_controller) do |generation_controller|
          request_generation(
            prompt,
            generation_controller: generation_controller,
            cancel_controller: cancel_controller,
            model_name: resolved_model_name,
            on_chunk: lambda { |chunk|
              generation_usage = context.capture(chunk[:payload]) || generation_usage
              # llama.cpp names the loaded model in the stream's last payload.
              named = chunk[:payload]["model"] if chunk[:payload].is_a?(Hash)
              served_model = named if named.is_a?(String) && !named.strip.empty?
              split = stream_splitter.feed(chunk[:content])
              partial_assistant_buffer << split[:text]
              streamed_thinking += split[:thinking].to_s.length
              if on_stream_event
                emit_stream_event(
                  on_stream_event,
                  type: :generation_chunk,
                  iteration: iteration_index + 1,
                  content: chunk[:content],
                  thinking: split[:thinking],
                  payload: chunk[:payload]
                )
              end
            },
            on_retry: lambda { |retry_event|
              # The retry streams from the start: its counts replace these.
              generation_usage = nil
              streamed_thinking = 0
              next unless on_stream_event

              emit_stream_event(
                on_stream_event,
                {
                  type: :generation_retrying,
                  iteration: iteration_index + 1
                }.merge(retry_event)
              )
            },
            images: images
          )
        rescue Client::RequestCancelled
          raise unless cut?(generation_controller, cancel_controller)

          cut = generation_controller.detail || {}
          ""
        end
        if cut
          # The cut stream may have stopped mid-block, and its visible text
          # goes with it: a fresh splitter, the buffer as it was before.
          stream_splitter = ThoughtStreamSplitter.for_profile(@profile)
          partial_assistant_buffer.slice!(buffer_mark..)
          emit_stream_event(on_stream_event, type: :generation_completed, iteration: iteration_index + 1,
                                             content_length: 0, thinking_chars: streamed_thinking,
                                             served_model: served_model, requested_model: resolved_model_name,
                                             finish_reason: "stopped", stopped_by: cut[:by], stop_reason: cut[:reason])
          # A Stop that came right after the cut is a plain cancel.
          raise Client::RequestCancelled.new(cancel_controller.reason) if cancel_controller.cancelled?

          if empty_retries < empty_retry_limit
            # Queued input (the user's line, a plugin's steer) goes in place of the nudge.
            next if inject_pending_input!(conversation, pending_input, on_stream_event, iteration_index + 1, cancel_controller)

            empty_retries += 1
            @retry_generation = true
            emit_stream_event(on_stream_event, type: :empty_answer_retry, iteration: iteration_index + 1,
                                               attempt: empty_retries, of: empty_retry_limit,
                                               thinking_chars: streamed_thinking, stopped_by: cut[:by])
            conversation << TurnNote.cut_retry(cut[:by], cut[:reason])
            next
          end
          # No retry left: the turn ends as cancelled (hook), with nothing
          # salvaged and without the spent nudge.
          drop_last_empty_retry!(conversation)
          cancel_controller.cancel!(:hook)
          emit_stream_event(on_stream_event, type: :generation_cancelled, iteration: iteration_index + 1, reason: :hook)
          return cancelled_result(conversation, tool_activity: tool_activity, reason: :hook, partial_assistant_text: "")
        end
        context.generation_done(generation_usage, prompt_chars: prompt.length, image_tokens: image_tokens, window: context_window)
        emit_stream_event(
          on_stream_event,
          type: :generation_completed,
          iteration: iteration_index + 1,
          content_length: response.to_s.length,
          thinking_chars: thinking_chars(response.to_s, streamed_thinking),
          served_model: served_model,
          requested_model: resolved_model_name
        )
        dump_log("response", response, iteration: iteration_index + 1)
        # Fire :after_generation hook (after LLM returns, before tool parse),
        # with a read-only copy of the conversation as sent.
        after_gen_event = { type: :after_generation, iteration: iteration_index + 1, response: response,
                            messages: AnswerDisplay.strip_all(conversation).map(&:dup).freeze }
        fire_hook(:after_generation, after_gen_event) if @hooks
        conversation << { role: "model", content: prefill + response.to_s }

        # Profile-specific parse (incl. Qwen unterminated-block recovery); the
        # returned fragment (non-nil only for Qwen) is fed back on the next
        # iteration if the model opened a tool-call block it did not close.
        calls, qwen_partial_tool_call = parser.parse_with_recovery(response, qwen_partial_tool_call)
        calls = calls.map do |call|
          PromptLiteralGuard.restore_call(call, profile: @profile)
        end
        qwen_incomplete_tool_call = !qwen_partial_tool_call.nil?

        if calls.empty?
          if qwen_incomplete_tool_call && qwen_recovery_attempts < QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_LIMIT
            qwen_recovery_attempts += 1
            conversation << { role: "user", content: QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_PROMPT, preserve_literals: true }
            pending_tool_calls = false
            next
          end

          pending_tool_calls = false
          answer = -> { PromptLiteralGuard.restore(strip_thought_blocks(response), profile: @profile) }
          empty = strip_thought_blocks(response.to_s).strip.empty?
          retry_empty = empty && empty_retries < empty_retry_limit && !cancel_controller&.cancelled?
          # The empty generation goes (its thinking would be sent again and
          # prime the same loop); an empty answer that will be retried is no
          # answer site, so a plugin's steer joins the retry.
          conversation.pop if retry_empty
          unless inject_pending_input!(conversation, pending_input, on_stream_event, iteration_index + 1, cancel_controller,
                                       answer: retry_empty ? nil : answer)
            if retry_empty
              empty_retries += 1
              @retry_generation = true
              emit_stream_event(on_stream_event, type: :empty_answer_retry, iteration: iteration_index + 1,
                                                 attempt: empty_retries, of: empty_retry_limit,
                                                 thinking_chars: thinking_chars(response.to_s, streamed_thinking))
              conversation << TurnNote.empty_retry
              next
            end
            # The Engine's TurnNote.empty says it all: the spent nudge goes.
            drop_last_empty_retry!(conversation) if empty && empty_retries.positive?
            break
          end
          # Queued steering keeps the turn going: loop again so the model
          # answers the injected message instead of stopping here.
          next
        end

        qwen_recovery_attempts = 0
        qwen_partial_tool_call = nil

        emit_stream_event(on_stream_event, type: :tool_dispatch_started, iteration: iteration_index + 1, call_count: calls.length)
        tool_images = []
        image_counts = []
        shown_params = []
        shown_labels = []
        diffs = []
        results = calls.map.with_index do |call, call_index|
          run = tool_runner.run(call, iteration: iteration_index + 1, call_index: call_index + 1,
                                      call_count: calls.length, on_stream_event: on_stream_event,
                                      max_tool_output_chars: effective_max_tool_output_chars)
          tool_activity << run[:activity]
          tool_images.concat(Array(run[:images]))
          image_counts << Array(run[:images]).size
          shown_params << run[:shown_params]
          shown_labels << run[:shown_label]
          diffs << run[:diff]
          run[:output]
        end.join("\n\n---\n\n")
        emit_stream_event(on_stream_event, type: :tool_dispatch_completed, iteration: iteration_index + 1, call_count: calls.length)
        # The joined results carry every call's images, in call order.
        tool_response = { role: "tool_response", content: results }
        tool_response[:images] = tool_images unless tool_images.empty?
        # How many of them each call returned, in call order, so the web's
        # reload puts each on its own tool row; the prompt never reads it.
        tool_response[:image_counts] = image_counts unless tool_images.empty?
        # A plugin tool's params line, one per call in call order (nil for
        # a built-in), for the web's reload; the prompt never reads it.
        tool_response[:tool_params] = shown_params if shown_params.any?
        tool_response[:tool_labels] = shown_labels if shown_labels.any?
        # What each edit/write changed (nil for other calls), in call order,
        # for the web's reload; the prompt never reads it.
        tool_response[:tool_diffs] = diffs if diffs.any?
        conversation << tool_response
        pending_tool_calls = true
      rescue Client::RequestCancelled => e
        emit_stream_event(
          on_stream_event,
          type: :generation_cancelled,
          iteration: iteration_index + 1,
          reason: e.reason
        )
        return cancelled_result(conversation, tool_activity: tool_activity, reason: e.reason, partial_assistant_text: partial_assistant_buffer)
      end

      if pending_tool_calls && tool_response_turn?(conversation.last)
        exhausted = true
      end

      output = strip_thought_blocks(last_model_content(conversation))
      # A turn stopped at the limit ends on a call it never ran: show only its text.
      output = parser.strip_tool_calls(output) if exhausted
      Result.new(
        output: PromptLiteralGuard.restore(output, profile: @profile),
        conversation: duplicate_conversation(conversation),
        exhausted: exhausted,
        pending_tool_calls: pending_tool_calls,
        tool_activity: tool_activity,
        canceled: false,
        cancellation_reason: nil,
        context_status: context.display
      )
    rescue StandardError => e
      LLM::FailedTurn.attach(e, conversation && duplicate_conversation(conversation))
      raise
    end

    # Use a resolved profile (ModelProfile::Resolution) from now on,
    # whatever model name later runs carry.
    def use_profile!(resolution)
      @profile = resolution.profile
      @profile_source = resolution.label
    end

    def sync_model_key!(key)
      @model_key = key
    end

    private

    # memory_read with the session's mutes applied: a blank name (the index)
    # loses the muted memories' lines; a muted name in a comma list is
    # refused with its own error line and the rest is read as usual.
    def muted_memory_read(tool, call)
      muted = Array(@muted_memory_names)
      content = call[:content].to_s
      read = ->(names) { tool.call(names, scope: call[:scope], model_key: @model_key) }
      return read.call(content) if muted.empty?
      return MutedMemories.filter_index(read.call(content), muted) if content.strip.empty?

      names = Tools::MemoryRead.parse_names(content)
      refused, allowed = names.partition { |name| MutedMemories.muted?(name, muted) }
      return read.call(content) if refused.empty?

      errors = refused.map { |name| "Error: memory '#{name}' is muted for this session" }
      return errors.join("\n") if allowed.empty?

      [read.call(allowed.join(",")), *errors].join(Tools::MemoryRead::SEPARATOR)
    end

    def emit_stream_event(callback, event)
      callback&.call(event)
    rescue StandardError
      nil
    end

    # Drain the pending input queue (if any) and, when messages are waiting,
    # append them as ONE merged user message at the conversation tail and emit
    # :pending_input_merged. Tail-append only: head mutation would invalidate
    # the server-side prefix KV cache. Returns true when a message was injected.
    # A plugin's steers (Steer) follow the user's message, each its own
    # message; after an answer the Engine's drain has already dropped them.
    # After a cancel the input stays queued: it runs as the next turn instead
    # of dying with this one. +answer+ (a proc, called only on a merge) is the
    # answer the merge follows: the UIs show it, the turn summary has only the
    # last one.
    def inject_pending_input!(conversation, pending_input, on_stream_event, iteration, cancel_controller = nil, answer: nil)
      return false unless pending_input
      return false if cancel_controller&.cancelled?

      merge = Steer.merge(Steer.drain(pending_input, at_answer: !answer.nil?))
      return false if merge.empty?

      answer = answer.call.to_s if answer
      conversation.concat(merge.messages)
      emit_stream_event(
        on_stream_event,
        type: :pending_input_merged,
        iteration: iteration,
        **merge.event_fields,
        answer: answer.to_s.strip.empty? ? nil : answer
      )
      true
    end

    # ── Hook dispatch helper ───────────────────────────────────────────────────

    # Fire a named hook on the registry (if present).
    # Hooks are dispatched synchronously; the event hash is passed by reference
    # so hooks can mutate fields (e.g. :before_tool_call can modify :call).
    def tool_runner
      @tool_runner ||= ToolRunner.new(self)
    end

    def fire_hook(name, event)
      return unless @hooks
      @hooks.fire(name, event)
    rescue StandardError
      # A failing hook must not break the turn.
    end

    # Coerce a value to boolean — handles true/false, nil, and string "true"/"false".
    def truthy?(val) = Tools::Builtins.truthy?(val)

    def tool_context = @tool_context ||= ToolContext.new(self)

    # ── Output char cap resolution ─────────────────────────────────────────────

    # Resolve the per-output character cap for the emitted tool call events.
    #
    # Precedence: an explicit override wins, then max_tool_output_chars
    # (Config). A non-positive value falls back to
    # DEFAULT_MAX_TOOL_OUTPUT_CHARS (there is intentionally no "unlimited" — live UIs get a
    # bounded `output:` plus a truthful `output_truncated:` flag).
    # Class-level so the chat loop resolves it the same way.
    def self.resolve_output_char_cap(override)
      parsed = (override || Samagotchi::Config.get("max_tool_output_chars")).to_i
      parsed.positive? ? parsed : DEFAULT_MAX_TOOL_OUTPUT_CHARS
    end

    def resolve_output_char_cap(override)
      self.class.resolve_output_char_cap(override)
    end

    # One request, cancelled by +generation_controller+ (the turn's child)
    # when there is one.
    def request_generation(prompt, generation_controller:, cancel_controller:, **options)
      @client.complete(prompt, **complete_kwargs(cancel_controller: generation_controller || cancel_controller, **options))
    end

    # Yields the turn controller's child for one generation (nil without a
    # controller).
    def with_generation(cancel_controller, &block)
      return yield(nil) unless cancel_controller

      cancel_controller.generation(&block)
    end

    # The generation was cut (stop_generation) and the turn goes on.
    def cut?(generation_controller, cancel_controller)
      generation_controller&.cancelled? && !cancel_controller.cancelled?
    end

    def complete_kwargs(cancel_controller:, model_name: nil, on_chunk: nil, on_retry: nil, images: [])
      kwargs = {}
      # Only a request with images names them: a text-only call is unchanged.
      kwargs[:images] = images unless images.empty?
      kwargs[:on_chunk] = on_chunk if on_chunk
      kwargs[:on_retry] = on_retry if on_retry && client_supports_keyword?(:on_retry)
      kwargs[:cancel_controller] = cancel_controller if cancel_controller && client_supports_keyword?(:cancel_controller)
      kwargs[:stop] = @profile.stop_sequences if client_supports_keyword?(:stop)
      n_predict = completion_n_predict
      kwargs[:n_predict] = n_predict if n_predict && client_supports_keyword?(:n_predict)
      resolved_model_name = completion_model_name(model_name)
      kwargs[:model] = resolved_model_name if resolved_model_name && client_supports_keyword?(:model)
      sampling = @retry_generation ? EmptyAnswerRetry.sampling(@sampling) : @sampling
      @retry_generation = false
      kwargs[:sampling] = sampling if sampling && !sampling.empty? && client_supports_keyword?(:sampling)
      kwargs
    end

    def completion_n_predict
      value = Samagotchi::Config.get("default.n_predict").to_i
      value if value.positive?
    end

    def completion_model_name(override = nil)
      ModelProfile.required_model_name(override)
    end

    def client_supports_keyword?(keyword)
      @client_complete_keyword_support ||= {}
      return @client_complete_keyword_support[keyword] if @client_complete_keyword_support.key?(keyword)

      @client_complete_keyword_support[keyword] = begin
        parameters = @client.method(:complete).parameters
        parameters.any? { |kind, name| (kind == :key || kind == :keyreq) && name == keyword } ||
          parameters.any? { |kind, _name| kind == :keyrest }
      rescue StandardError
        false
      end
    end

    def cancelled_result(conversation, tool_activity:, reason:, partial_assistant_text: "")
      partial = partial_assistant_text.to_s.strip
      conversation = duplicate_conversation(conversation)
      # Salvage the already-streamed visible reply (thought/tool_call lanes
      # were never routed into the buffer, so unterminated tool_call fragments
      # cannot leak) so a follow-up steering message continues with the model's
      # half-finished work in context instead of losing it.
      unless partial.empty?
        conversation << { role: "model", content: "#{partial}\n[interrupted]", interrupted: true }
      end
      Result.new(
        output: "",
        conversation: conversation,
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: tool_activity,
        canceled: true,
        cancellation_reason: reason
      )
    end

    # A payload dump (model response, tool call/result, context status): the
    # debug level only, tagged with the model it came from.
    def dump_log(event, payload, **fields)
      return unless Log.level?(:debug)

      Log.debug(:model, event, payload: payload, model: @current_model_name, **fields)
    end

    # Estimate context usage for this iteration's prompt (ContextStatus#observe)
    # and, when the emit gate fires, surface it to stream consumers as a
    # :context_status event. The telemetry is not for the model (it used to
    # be injected as a synthetic system message).
    def emit_context_status_event(on_stream_event, context, prompt, iteration_index:, window:, image_tokens: 0)
      event = context.observe(prompt, iteration_index: iteration_index, window: window, image_tokens: image_tokens)
      return unless event

      emit_stream_event(on_stream_event, type: :context_status, iteration: iteration_index + 1, **event)
      dump_log("context_status", event[:status], iteration: iteration_index + 1, bucket: event[:bucket])
    end

    public

    # Public wrapper so other loops (e.g. the chat loop) can strip
    # per-profile thought blocks from finished model text without duplicating the
    # Gemma 4 / Qwen 3.6 logic. Mirrors the native loop's "strip before deciding
    # whether the model called a tool / returning the final answer".
    def strip_model_thought(text)
      strip_thought_blocks(text)
    end

    # The status line's context value ({est_pct:, bucket:}) for +used_tokens+
    # of +window_tokens+; nil without both, or with context.status off. The
    # chat loop builds its value with it too.
    def context_display(used_tokens:, window_tokens:)
      ContextStatus.new.display_for(used_tokens: used_tokens, window_tokens: window_tokens)
    end

    # Per-profile parse strategy. Rebuilt when the active profile changes
    # (the profile may be re-inferred per run when not explicitly pinned).
    # Public so other loops (and specs) can reach the active profile's parser.
    def parser
      @parser = ToolCallParser.for_profile(@profile) if @parser_profile != @profile
      @parser_profile = @profile
      @parser
    end
    private

    # The generation's thinking: what the stream split into the thinking
    # lane (Qwen), else what the profile's thought blocks hold (Gemma's
    # stream isn't split).
    def thinking_chars(response, streamed)
      return streamed if streamed.positive?

      response.length - strip_thought_blocks(response).length
    end

    # Remove thought blocks from model output. The format depends on profile
    # (Gemma 4 <|think|>/channel blocks vs Qwen 3.6 literal think tokens);
    # the per-profile logic lives in ToolCallParser.
    def strip_thought_blocks(text)
      parser.strip_thought(text)
    end

    def sanitize_history(messages)
      messages.map do |m|
        if m[:role] == "model"
          # `display` rides along so the stored conversation keeps it; the
          # prompt formatter never reads it (AnswerDisplay).
          { role: m[:role], content: strip_thought_blocks(m[:content].to_s), display: m[:display] }.compact
        else
          m.dup
        end
      end
    end

    def prepare_conversation(messages)
      if messages.is_a?(Result)
        duplicate_conversation(messages.conversation)
      else
        # Standard multi-turn compliance: never pass prior raw thought blocks.
        sanitize_history(messages)
      end
    end

    def duplicate_conversation(messages)
      messages.map(&:dup)
    end

    def drop_last_empty_retry!(conversation)
      index = conversation.rindex { |entry| TurnNote.retry_nudge?(entry) }
      conversation.delete_at(index) if index
    end

    def last_model_content(conversation)
      message = conversation.reverse.find { |entry| entry[:role] == "model" }
      message ? message[:content].to_s : ""
    end

    def tool_response_turn?(message)
      message && message[:role] == "tool_response"
    end

    public
    # Public entry point for executing an ALREADY-NORMALIZED internal tool call
    # (the {name:, content:, path:, scope:, …} shape).
    #
    # Other agentic loops — notably the chat loop's native tool calls
    # — need to execute tool calls through this single path so tool execution,
    # unknown-tool handling, and activity events are shared, not duplicated. Callers
    # are responsible for normalizing the provider's native call into this shape
    # first (see Samagotchi::LLM::NativeToolNormalizer); dispatch itself never
    # parses provider text.
    def dispatch_tool_call(call)
      dispatch(call)
    end

    private
    def dispatch(call)
      entry = @tools[call[:name]]
      unless entry
        available = @tools.names.join(", ")
        result = "Error: unknown tool '#{call[:name]}'. Available: #{available}"
        return {
          output: result,
          activity: ToolActivity.tool_activity_event(call[:name], call, result, registry: @tools)
        }
      end

      dump_log("tool_call", call[:content], tool: call[:name], path: call[:path], scope: call[:scope])

      result = entry.handler.call(call, tool_context)

      dump_log("tool_result", result, tool: call[:name])
      dispatched = {
        output: "[#{call[:name]}]\n#{result}",
        activity: ToolActivity.tool_activity_event(call[:name], call, result, registry: @tools)
      }
      # Images the tool returned (read's ImageResult, a plugin's ToolResult):
      # ToolRunner attaches them (or says why not).
      if result.respond_to?(:images) && !Array(result.images).empty?
        dispatched[:images] = Array(result.images)
        dispatched[:image_only] = true if result.respond_to?(:image_only?) && result.image_only?
      end
      dispatched
    rescue => e
      dump_log("tool_error", e.message, tool: call[:name], error: e.class.name)
      result = "Error: #{e.message}"
      {
        output: "[#{call[:name]}] #{result}",
        activity: ToolActivity.tool_activity_event(call[:name], call, result, registry: @tools)
      }
    end

    # ask_user_question: validate the call, then hand the payload to the
    # Engine's question flow (question_handler, which blocks until the user
    # answers). Without one (headless), the payload as JSON so the model sees
    # the options and can ask in plain text.
    def handle_ask_user_question(call)
      payload = Samagotchi::Tools::AskUserQuestion.validate(call)
      return payload if payload.is_a?(String)
      return JSON.pretty_generate(payload) unless @question_handler

      @question_handler.call(payload).to_s
    rescue => e
      "Error: ask_user_question handler failed: #{e.message}"
    end
  end
end
