# frozen_string_literal: true

require_relative "iteration_limit"
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
require_relative "tool_response"
require_relative "answer_display"
require_relative "llm/model_result"
require_relative "llm/turn_settings"

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
    # The built-in tool classes (Tools::Builtins registers them).
    TOOLS = Tools::Builtins::CLASSES

    # What a tool handler (call, kctx) gets from the kernel: the reminder
    # store, the peers, the model key, and the memory read and ask-user
    # flows that need its state (read through the kernel's public readers).
    class ToolContext
      def initialize(kernel)
        @kernel = kernel
      end

      def reminder_store = @kernel.reminder_store
      def peers = @kernel.peers
      def model_key = @kernel.model_key

      # memory_read with the session's mutes applied: a blank name (the index)
      # loses the muted memories' lines; a muted name in a comma list is
      # refused with its own error line and the rest is read as usual.
      def muted_memory_read(call)
        muted = Array(@kernel.muted_memory_names)
        content = call[:content].to_s
        read = lambda do |names|
          Tools::MemoryRead.call(names, scope: call[:scope], model_key: model_key, fallback_model_key: @kernel.model_key_fallback)
        end
        return read.call(content) if muted.empty?
        return MutedMemories.filter_index(read.call(content), muted) if content.strip.empty?

        names = Tools::MemoryRead.parse_names(content)
        refused, allowed = names.partition { |name| MutedMemories.muted?(name, muted) }
        return read.call(content) if refused.empty?

        errors = refused.map { |name| "Error: memory '#{name}' is muted for this session" }
        return errors.join("\n") if allowed.empty?

        [read.call(allowed.join(",")), *errors].join(Tools::MemoryRead::SEPARATOR)
      end

      # ask_user_question: validate the call, then hand the payload to the
      # Engine's question flow (the kernel's question_handler, which blocks
      # until the user answers). Without one (headless), the payload as JSON
      # so the model sees the options and can ask in plain text.
      def ask_user_question(call)
        payload = Tools::AskUserQuestion.validate(call)
        return payload if payload.is_a?(String)

        handler = @kernel.question_handler
        return JSON.pretty_generate(payload) unless handler

        handler.call(payload).to_s
      rescue StandardError => e
        "Error: ask_user_question handler failed: #{e.message}"
      end
    end

    DEFAULT_MAX_TOOL_OUTPUT_CHARS = 10_000
    QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_LIMIT = 2
    QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_PROMPT = "Continue the previous assistant message by finishing the open <tool_call> XML block. Output only the remaining XML needed to complete the tool call."

    # @param tools [Tools::Registry, nil] the tools calls dispatch to (the
    #   Engine's; nil: the built-ins alone)
    def initialize(client: nil, profile: nil, model_name: nil, hooks: nil, reminder_store: nil, model_key: nil, tools: nil)
      @client = client || Client.new
      @tools = tools || Tools::Builtins.default
      resolved_model_name = ModelProfile.required_model_name(model_name)
      # The turn's settings (LLM::TurnSettings). Its model name is the
      # resolved model id actually used for this run (per-run override wins
      # over the config alias); on every debug dump so we can see exactly
      # which model each request went to. The Engine sets them per turn:
      # the chat loop dispatches tools here without going through #run.
      @turn_settings = LLM::TurnSettings.none.with(model_name: resolved_model_name)
      @profile = profile ? ModelProfile.normalize(profile) : ModelProfile.from_model_name(resolved_model_name)
      # Where @profile came from, as /stats shows it (a Resolution's label
      # once the Engine resolves one, see #use_profile!).
      @profile_source = profile ? "given" : "name"
      @hooks = hooks
      @reminder_store = reminder_store
      @model_key = model_key
      @model_key_fallback = nil
    end

    # @return [ReminderStore, nil] the reminder store the reminder tools
    #   write; the Engine's own (it hands it to a kernel it was given).
    attr_accessor :reminder_store

    # @return [ModelProfile] the active prompt profile
    attr_reader :profile

    # @return [Samagotchi::Hooks::Registry, nil] hooks registry shared with Engine.
    #   Engine owns the registry; KernelLoop only fires events. Accessor allows
    #   Engine to hand its registry to a kernel it is given (specs).
    attr_accessor :hooks
    # @return [Tools::Registry] the tools #dispatch runs. The Engine sets
    #   its own on a kernel it is given, as with hooks.
    attr_accessor :tools
    attr_accessor :client, :model_key
    # @return [String, nil] the key whose overlay memory_read takes when
    #   #model_key has none (#sync_model_key!)
    attr_reader :model_key_fallback
    # @return [Array<String>, nil] the session's muted memories (normalized
    #   names, see MutedMemories); memory_read refuses them. The Engine sets it.
    attr_accessor :muted_memory_names
    # @return [Proc, nil] answers ask_user_question (payload → answer string);
    #   Engine sets it to its blocking request_question.
    attr_accessor :question_handler
    # The Guardrails::Gate ToolRunner asks before each call; the Engine sets
    # it (nil: ToolRunner's own, hooks only).
    attr_accessor :guardrail_gate
    # @return [LLM::TurnSettings] the turn's vision, sampling, thinking and
    #   model name, set by the Engine per turn (#run sets the model name
    #   too); the thinking level is its own field, since the native path
    #   sends the sampling as is.
    attr_accessor :turn_settings
    # Tools::Peers (or the Engine's live view of it): the session
    # list_sessions and send_note speak for; nil outside a session.
    attr_accessor :peers

    # Run the conversation loop and return the final model response plus
    # resumable conversation state when execution stops at max_iterations.
    #
    # @param messages       [Array<Hash>]        conversation so far ({role:, content:});
    #   a stopped run resumes from its result's #conversation
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
    # @return [LLM::ModelResult] final visible response with continuation metadata
    def run(messages, max_iterations: IterationLimit::DEFAULT, on_stream_event: nil, cancel_controller: nil, model_name: nil, max_tool_output_chars: nil, pending_input: nil)
      @turn_settings = @turn_settings.with(model_name: completion_model_name(model_name))
      turn = start_turn(messages, on_stream_event: on_stream_event, cancel_controller: cancel_controller,
                                  pending_input: pending_input, cap: resolve_output_char_cap(max_tool_output_chars))

      max_iterations.times do |iteration_index|
        turn.iteration = iteration_index + 1
        outcome = iterate(turn)
        return outcome if outcome.is_a?(LLM::ModelResult)
        break if outcome == :answer
      rescue Client::RequestCancelled => e
        emit(turn, type: :generation_cancelled, iteration: turn.iteration, reason: e.reason)
        return cancelled_result(turn.conversation, tool_activity: turn.tool_activity, reason: e.reason,
                                                   partial_assistant_text: turn.buffer)
      end
      finish(turn)
    rescue StandardError => e
      LLM::FailedTurn.attach(e, turn && duplicate_conversation(turn.conversation))
      raise
    end

    # Use a resolved profile (ModelProfile::Resolution) from now on,
    # whatever model name later runs carry.
    def use_profile!(resolution)
      @profile = resolution.profile
      @profile_source = resolution.label
    end

    # @param fallback [String, nil] a key whose overlay memory_read takes
    #   when +key+ has none (the alias a model was typed as)
    def sync_model_key!(key, fallback: nil)
      @model_key = key
      @model_key_fallback = fallback
    end

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

    private

    # ── One turn (#run) ────────────────────────────────────────────────────────

    # One run's state, threaded through its steps: the conversation, the
    # context tracker and the retry budget, the tool activity, the visible
    # text streamed so far (salvaged on a cancel), the Qwen recovery state,
    # the prefill, and what the caller gave.
    Turn = Struct.new(:conversation, :context, :empty_retry, :tool_activity, :buffer, :qwen_attempts, :qwen_partial,
                      :prefill, :pending_tool_calls, :model_name, :pending_input, :on_stream_event,
                      :cancel_controller, :cap, :emit, :iteration, :empty_steps, :ended_empty, keyword_init: true)
    # One request: the prompt and its images as sent, the images' token
    # estimate, and the window it was measured against.
    Request = Struct.new(:prompt, :images, :image_tokens, :window, :prefill, keyword_init: true)
    # One generation: the response (nil when cut), the cut's detail, this
    # generation's own server counts, the model the server named, the
    # thinking it streamed, and why it stopped (the transport's finish
    # reason, Client::Transport#finish_reason_from; nil when not named).
    Generation = Struct.new(:response, :cut, :usage, :served_model, :streamed_thinking, :finish_reason, keyword_init: true)
    private_constant :Turn, :Request, :Generation

    def start_turn(messages, on_stream_event:, cancel_controller:, pending_input:, cap:)
      conversation = prepare_conversation(messages)
      Turn.new(
        conversation: conversation, context: ContextStatus.new(conversation: conversation),
        empty_retry: EmptyAnswerRetry.new, empty_steps: [], tool_activity: [], buffer: +"", qwen_attempts: 0, qwen_partial: nil,
        # Qwen with thinking off: an empty thought after the cue, so the model
        # answers at once. Kept in the turn's model messages, so each tool-loop
        # prompt starts with what the server already has cached.
        prefill: Thinking.native(@turn_settings.thinking || Thinking::DEFAULT, @profile).prefill,
        pending_tool_calls: false, model_name: @turn_settings.model_name, pending_input: pending_input,
        on_stream_event: on_stream_event, cancel_controller: cancel_controller, cap: cap,
        emit: ->(event) { emit_stream_event(on_stream_event, event) }
      )
    end

    # One iteration. Returns :next, :answer (the turn ends), or the turn's
    # result (it ended cancelled).
    def iterate(turn)
      inject_pending_input!(turn)
      request = prepare_request(turn)
      generation = generate(turn, request)
      return after_cut(turn, generation) if generation.cut

      turn.conversation << { role: "model", content: request.prefill + generation.response.to_s }
      # Profile-specific parse (incl. Qwen unterminated-block recovery); the
      # returned fragment (non-nil only for Qwen) is fed back on the next
      # iteration if the model opened a tool-call block it did not close.
      calls, turn.qwen_partial = parser.parse_with_recovery(generation.response, turn.qwen_partial)
      calls = calls.map { |call| PromptLiteralGuard.restore_call(call, profile: @profile) }
      return after_text(turn, request, generation) if calls.empty?

      dispatch_calls(turn, calls)
    end

    # The prompt for this iteration, after the context check: a rise into a
    # bucket that asks the model for a change puts its line on the tail
    # (the prompt cache keeps its prefix), and the prompt is formatted again
    # with it.
    def prepare_request(turn)
      prompt, images = format_prompt(turn)
      image_tokens = images.empty? ? 0 : ImagePlan.estimated_tokens(turn.conversation)
      window = ContextWindow.resolve(client: @client, model: turn.model_name, setting: @turn_settings.window_setting)
      emit_context_status_event(turn.on_stream_event, turn.context, prompt, iteration_index: turn.iteration - 1,
                                                                             window: window, image_tokens: image_tokens)
      if (line = turn.context.take_guidance)
        turn.conversation << line
        prompt, images = format_prompt(turn)
      end
      # The prefill the prompt ended with (none where Gemma's turn goes on
      # after a tool response): the model message keeps it.
      prefill = Prompt.prefill_for(turn.conversation, @profile, turn.prefill)
      Request.new(prompt: prompt, images: images, image_tokens: image_tokens, window: window, prefill: prefill)
    end

    def format_prompt(turn)
      Prompt.format_with_images(turn.conversation, profile: @profile, vision: @turn_settings.vision, prefill: turn.prefill)
    end

    # One streamed request, under the generation's own controller: a
    # plugin's stop_generation cuts it alone, and the turn goes on (a cut).
    # Ends with its :generation_completed (and, unless cut, the
    # after_generation hook).
    def generate(turn, request)
      # Each generation splits its own stream: one that ended inside a
      # thought or a tool call doesn't leave the next one "inside" it.
      stream_splitter = ThoughtStreamSplitter.for_profile(@profile)
      emit(turn, type: :generation_started, iteration: turn.iteration, context_window_tokens: request.window.tokens,
                 context_window_source: request.window.source, profile: @profile.name, profile_source: @profile_source)
      # This generation's own server counts (the run-long ones in the
      # context tracker can be an earlier one's), and the thinking it
      # streamed, for the log (a stuck thinking generation shows as
      # thinking_chars=N content_length=…).
      generation = Generation.new(usage: nil, served_model: nil, streamed_thinking: 0)
      fire_hook(:before_generation, { type: :before_generation, iteration: turn.iteration }) if @hooks
      buffer_mark = turn.buffer.length
      generation.response = with_generation(turn.cancel_controller) do |generation_controller|
        request_generation(
          request.prompt,
          generation_controller: generation_controller,
          cancel_controller: turn.cancel_controller,
          model_name: turn.model_name,
          sampling: turn.empty_retry.request_sampling(@turn_settings.sampling),
          on_chunk: ->(chunk) { stream_chunk(turn, generation, stream_splitter, chunk) },
          on_retry: lambda { |retry_event|
            # The retry streams from the start: its counts replace these.
            generation.usage = nil
            generation.streamed_thinking = 0
            generation.finish_reason = nil
            turn.emit.call({ type: :generation_retrying, iteration: turn.iteration }.merge(retry_event)) if turn.on_stream_event
          },
          images: request.images
        )
      rescue Client::RequestCancelled
        raise unless cut?(generation_controller, turn.cancel_controller)

        generation.cut = generation_controller.detail || {}
        nil
      end
      generation.cut ? cut_generation(turn, generation, buffer_mark) : completed_generation(turn, request, generation)
      generation
    end

    def stream_chunk(turn, generation, stream_splitter, chunk)
      generation.usage = turn.context.capture(chunk[:payload]) || generation.usage
      # llama.cpp names the loaded model in the stream's last payload.
      named = chunk[:payload]["model"] if chunk[:payload].is_a?(Hash)
      generation.served_model = named if named.is_a?(String) && !named.strip.empty?
      generation.finish_reason = chunk[:finish_reason] if chunk[:finish_reason]
      split = stream_splitter.feed(chunk[:content])
      turn.buffer << split[:text]
      generation.streamed_thinking += split[:thinking].to_s.length
      return unless turn.on_stream_event

      event = { type: :generation_chunk, iteration: turn.iteration, content: chunk[:content], text: split[:text],
                thinking: split[:thinking], payload: chunk[:payload] }
      # A chunk of a tool call (its bytes are dropped from both lanes): a
      # steer doesn't cut this generation (Engine#cut_for_steer).
      event[:tool_call] = true if split[:tool]
      emit(turn, **event)
    end

    # The cut stream's visible text goes with it: the buffer as it was
    # before (the next generation gets a fresh splitter).
    def cut_generation(turn, generation, buffer_mark)
      turn.buffer.slice!(buffer_mark..)
      emit(turn, type: :generation_completed, iteration: turn.iteration, content_length: 0,
                 thinking_chars: generation.streamed_thinking, served_model: generation.served_model,
                 requested_model: turn.model_name, finish_reason: "stopped", stopped_by: generation.cut[:by],
                 stop_reason: generation.cut[:reason])
    end

    def completed_generation(turn, request, generation)
      response = generation.response.to_s
      turn.context.generation_done(generation.usage, prompt_chars: request.prompt.length, image_tokens: request.image_tokens,
                                                     window: request.window)
      emit(turn, type: :generation_completed, iteration: turn.iteration, content_length: response.length,
                 thinking_chars: thinking_chars(response, generation.streamed_thinking),
                 served_model: generation.served_model, requested_model: turn.model_name,
                 finish_reason: generation.finish_reason)
      dump_log("response", generation.response, iteration: turn.iteration)
      # The after_generation hook (after the model returns, before the tool
      # parse), with a read-only copy of the conversation as sent.
      return unless @hooks

      fire_hook(:after_generation, { type: :after_generation, iteration: turn.iteration, response: generation.response,
                                     messages: AnswerDisplay.strip_all(turn.conversation).map(&:dup).freeze })
    end

    # A generation a plugin cut is an empty answer made early. Queued input
    # (a user's line, a plugin's steer) goes in first, with or without a
    # retry left, and spends no attempt: the model answers it. A steer's cut
    # (Engine#cut_for_steer) with nothing queued (its message was taken at
    # a boundary already) is asked again as is. Else it is asked again with
    # its own nudge while the retry budget lasts, else the turn ends as
    # cancelled (hook), with nothing salvaged and without the spent nudge.
    # A Stop that came right after the cut is a plain cancel. Returns :next
    # or the turn's result.
    def after_cut(turn, generation)
      cut = generation.cut
      raise Client::RequestCancelled, turn.cancel_controller.reason if turn.cancel_controller.cancelled?
      return :next if inject_pending_input!(turn) || cut[:steer]

      if turn.empty_retry.left?
        turn.empty_retry.nudge!(turn.conversation, TurnNote.cut_retry(cut[:by], cut[:reason]),
                                emit: turn.emit, iteration: turn.iteration, finish_reason: "stopped",
                                thinking_chars: generation.streamed_thinking, stopped_by: cut[:by])
        return :next
      end
      turn.empty_retry.drop_nudge!(turn.conversation)
      turn.cancel_controller.cancel!(:hook, cut)
      emit(turn, type: :generation_cancelled, iteration: turn.iteration, reason: :hook)
      cancelled_result(turn.conversation, tool_activity: turn.tool_activity, reason: :hook, partial_assistant_text: "")
    end

    # A generation with no tool calls: a Qwen call left open is asked to be
    # finished; an empty answer is asked again (EmptyAnswerRetry: not when
    # a length stop came with the context full); queued input keeps the
    # turn going (the model answers it); else it is the answer. Returns
    # :next or :answer.
    def after_text(turn, request, generation)
      turn.pending_tool_calls = false
      if turn.qwen_partial && turn.qwen_attempts < QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_LIMIT
        turn.qwen_attempts += 1
        turn.conversation << { role: "user", content: QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_PROMPT, preserve_literals: true }
        return :next
      end

      response = generation.response
      answer = -> { PromptLiteralGuard.restore(strip_thought_blocks(response), profile: @profile) }
      empty = strip_thought_blocks(response.to_s).strip.empty?
      retry_empty = empty && turn.empty_retry.retry_empty?(iteration: turn.iteration,
                                                           cancelled: turn.cancel_controller&.cancelled?,
                                                           finish_reason: generation.finish_reason,
                                                           used_tokens: generation.usage&.dig(:total_tokens),
                                                           window_tokens: request.window.tokens)
      # The empty generation goes (its thinking would be sent again and
      # prime the same loop); an empty answer that will be retried is no
      # answer site, so a plugin's steer joins the retry.
      turn.empty_steps << turn.conversation.pop if retry_empty
      # Queued steering keeps the turn going: the model answers the
      # injected message instead of stopping here.
      return :next if inject_pending_input!(turn, answer: retry_empty ? nil : answer)

      # The last one goes too: earlier thinking is stripped from the prompt,
      # so it would be an empty assistant turn there. The UIs draw it from
      # the result's empty_steps.
      if empty && !retry_empty
        turn.empty_steps << turn.conversation.pop
        turn.ended_empty = true
      end
      if retry_empty
        turn.empty_retry.nudge!(turn.conversation, TurnNote.empty_retry,
                                emit: turn.emit, iteration: turn.iteration, finish_reason: generation.finish_reason,
                                thinking_chars: thinking_chars(response.to_s, generation.streamed_thinking))
        return :next
      end
      # The Engine's TurnNote.empty says it all: the spent nudge goes.
      turn.empty_retry.drop_nudge!(turn.conversation) if empty && turn.empty_retry.used?
      :answer
    end

    # The batch runs (ToolResponse) and its results go back as one entry.
    def dispatch_calls(turn, calls)
      turn.qwen_attempts = 0
      turn.qwen_partial = nil
      runs = ToolResponse.run_batch(tool_runner, calls, iteration: turn.iteration, emit: turn.emit,
                                                        on_stream_event: turn.on_stream_event, cap: turn.cap)
      turn.tool_activity.concat(ToolResponse.activities(runs))
      # One entry for the batch: the full outputs joined (ToolResponse.joined).
      turn.conversation << ToolResponse.joined(runs)
      turn.pending_tool_calls = true
      :next
    end

    # The turn's result. It is exhausted only when it stopped on tool
    # results it never answered (so exhausted? alone means resumable?);
    # then the answer shows only its text.
    def finish(turn)
      exhausted = turn.pending_tool_calls && tool_response_turn?(turn.conversation.last)
      # An empty answer left the conversation: an earlier model message
      # isn't this turn's answer.
      output = turn.ended_empty ? "" : strip_thought_blocks(last_model_content(turn.conversation))
      output = parser.strip_tool_calls(output) if exhausted
      LLM::ModelResult.new(
        text: PromptLiteralGuard.restore(output, profile: @profile).to_s,
        conversation: duplicate_conversation(turn.conversation),
        exhausted: exhausted,
        pending_tool_calls: turn.pending_tool_calls,
        tool_activity: turn.tool_activity,
        context_status: turn.context.display,
        empty_steps: turn.empty_steps,
        empty_retries: turn.empty_retry.attempts
      )
    end

    def emit(turn, **event)
      emit_stream_event(turn.on_stream_event, event)
    end

    # Queued input at an iteration boundary (Steer.inject!); +answer+ is a
    # proc, built only on a merge. Returns true when anything was injected.
    def inject_pending_input!(turn, answer: nil)
      Steer.inject!(turn.conversation, turn.pending_input, iteration: turn.iteration, emit: turn.emit,
                                                           cancel_controller: turn.cancel_controller, answer: answer)
    end

    def emit_stream_event(callback, event)
      callback&.call(event)
    rescue StandardError
      nil
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

    def resolve_output_char_cap(override)
      self.class.resolve_output_char_cap(override)
    end

    # One request, cancelled by +generation_controller+ (the turn's child)
    # when there is one.
    def request_generation(prompt, generation_controller:, cancel_controller:, **)
      @client.complete(prompt, **complete_kwargs(cancel_controller: generation_controller || cancel_controller, **))
    end

    # Yields the turn controller's child for one generation (nil without a
    # controller).
    def with_generation(cancel_controller, &)
      return yield(nil) unless cancel_controller

      cancel_controller.generation(&)
    end

    # The generation was cut (stop_generation) and the turn goes on.
    def cut?(generation_controller, cancel_controller)
      generation_controller&.cancelled? && !cancel_controller.cancelled?
    end

    # +sampling+: this request's (EmptyAnswerRetry#request_sampling).
    def complete_kwargs(cancel_controller:, model_name: nil, on_chunk: nil, on_retry: nil, images: [], sampling: nil)
      kwargs = {}
      # Only a request with images names them: a text-only call is unchanged.
      kwargs[:images] = images unless images.empty?
      kwargs[:on_chunk] = on_chunk if on_chunk
      kwargs[:on_retry] = on_retry if on_retry
      kwargs[:cancel_controller] = cancel_controller if cancel_controller
      kwargs[:stop] = @profile.stop_sequences
      max_tokens = Samagotchi::Config.max_tokens
      kwargs[:n_predict] = max_tokens if max_tokens
      resolved_model_name = completion_model_name(model_name)
      kwargs[:model] = resolved_model_name if resolved_model_name
      kwargs[:sampling] = sampling if sampling && !sampling.empty?
      kwargs
    end

    def completion_model_name(override = nil)
      ModelProfile.required_model_name(override)
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
      LLM::ModelResult.new(
        text: "",
        conversation: conversation,
        tool_activity: tool_activity,
        canceled: true,
        cancellation_reason: reason
      )
    end

    # A payload dump (model response, tool call/result, context status): the
    # debug level only, tagged with the model it came from.
    def dump_log(event, payload, **fields)
      return unless Log.level?(:debug)

      Log.debug(:model, event, payload: payload, model: @turn_settings.model_name, **fields)
    end

    # Estimate context usage for this iteration's prompt (ContextStatus#observe)
    # and, when the emit gate fires, surface it to stream consumers as a
    # :context_status event. The telemetry is not for the model (it used to
    # be injected as a synthetic system message).
    def emit_context_status_event(on_stream_event, context, prompt, iteration_index:, window:, image_tokens: 0)
      event = context.observe(prompt.length, iteration_index: iteration_index, window: window, image_tokens: image_tokens)
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
    # lane, else what the profile's thought blocks hold (an empty thought, a
    # bare Gemma <|think|> cue, a response that wasn't streamed).
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

    # Standard multi-turn compliance: never pass prior raw thought blocks.
    def prepare_conversation(messages) = sanitize_history(messages)

    def duplicate_conversation(messages)
      messages.map(&:dup)
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
    rescue StandardError => e
      dump_log("tool_error", e.message, tool: call[:name], error: e.class.name)
      result = "Error: #{e.message}"
      {
        output: "[#{call[:name]}] #{result}",
        activity: ToolActivity.tool_activity_event(call[:name], call, result, registry: @tools)
      }
    end
  end
end
