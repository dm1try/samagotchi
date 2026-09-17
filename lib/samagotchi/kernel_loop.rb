# frozen_string_literal: true

require_relative "model_profile"
require_relative "tool_call_parser"
require_relative "config"
require_relative "context_usage"
require_relative "prompt"
require_relative "prompt_literal_guard"
require_relative "client"
require_relative "debug_log"
require_relative "hooks"
require_relative "pending_input_queue"
require_relative "thought_stream_splitter"
require_relative "tools/execute"
require_relative "tools/read"
require_relative "tools/write"
require_relative "tools/memory"
require_relative "tools/edit"
require_relative "tools/task_create"
require_relative "tools/task_get"
require_relative "tools/task_list"
require_relative "tools/task_stop"
require_relative "tools/task_wait"
require_relative "tools/web_fetch"
require_relative "tools/image_read"
require_relative "tools/register_reminder"
require_relative "tools/cancel_reminder"
require_relative "tools/list_reminders"
require_relative "tools/ask_user_question"

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
      def to_s
        output.to_s
      end

      alias to_str to_s

      def ==(other)
        if other.is_a?(self.class)
          super
        else
          to_s == other
        end
      end

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

      # Struct/Enumerable defines include? with collection semantics, but the
      # historical KernelLoop#run contract returned a String. Keep include?
      # aligned with String#include? for backward compatibility.
      def include?(needle)
        to_s.include?(needle)
      end

      # Keep compatibility with existing callers/specs that treat run() as a
      # plain string (e.g., include?, match, start_with?).
      def method_missing(name, *args, &block)
        return to_s.public_send(name, *args, &block) if to_s.respond_to?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        to_s.respond_to?(name, include_private) || super
      end
    end

    TOOLS = [
      Tools::Execute,
      Tools::Read,
      Tools::Write,
      Tools::MemoryRead,
      Tools::MemoryWrite,
      Tools::Edit,
      Tools::TaskCreate,
      Tools::TaskGet,
      Tools::TaskList,
      Tools::TaskStop,
      Tools::TaskWait,
      Tools::WebFetch,
      Tools::RegisterReminder,
      Tools::CancelReminder,
      Tools::ListReminders,
      Tools::ImageRead,
      Tools::AskUserQuestion
    ].freeze

    CONTEXT_STATUS_PREFIX = "CONTEXT_STATUS"
    CONTEXT_STATUS_ENABLED_ENV = "SAMAGOTCHI_CONTEXT_STATUS"
    CONTEXT_WINDOW_TOKENS_ENV = "SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"
    CONTEXT_CHARS_PER_TOKEN_ENV = "SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"
    CONTEXT_THRESHOLDS_ENV = "SAMAGOTCHI_CONTEXT_STATUS_THRESHOLDS"
    CONTEXT_CADENCE_ENV = "SAMAGOTCHI_CONTEXT_STATUS_CADENCE"

    DEFAULT_CONTEXT_WINDOW_TOKENS = 256_000
    DEFAULT_CONTEXT_CHARS_PER_TOKEN = 4.0
    DEFAULT_CONTEXT_THRESHOLDS = [20, 40, 60, 80].freeze
    DEFAULT_CONTEXT_CADENCE = 0
    TOOL_ACTIVITY_PREVIEW_LIMIT = 80
    DEFAULT_MAX_TOOL_OUTPUT_CHARS = 10_000
    TOOL_OUTPUT_CHARS_ENV = "SAMAGOTCHI_MAX_TOOL_OUTPUT_CHARS"
    QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_LIMIT = 2
    QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_PROMPT = "Continue the previous assistant message by finishing the open <tool_call> XML block. Output only the remaining XML needed to complete the tool call."

    def initialize(client: nil, verbose: false, log_file: nil, debug_log: nil, profile: nil, model_name: nil, no_interrupt: false, hooks: nil, reminder_store: nil, model_key: nil)
      @client = client || Client.new
      @verbose = verbose
      @debug_log = debug_log || DebugLog.new(path: log_file)
      @profile_explicit = !profile.nil?
      @no_interrupt = no_interrupt
      resolved_model_name = ModelProfile.required_model_name(model_name)
      # The resolved model id actually used for this run (per-run override wins
      # over the config alias); surfaced in debug/verbose logs so we can see
      # exactly which model each request went to.
      @current_model_name = resolved_model_name
      @profile = profile ? ModelProfile.normalize(profile) : ModelProfile.from_model_name(resolved_model_name)
      @hooks = hooks
      @reminder_store = reminder_store
      @model_key = model_key
    end

    # @return [ReminderStore, nil] the reminder store for inspection (used by
    #   Engine to share the same store with the KernelLoop when TerminalUI
    #   creates both).
    attr_reader :reminder_store

    # @return [Samagotchi::Hooks::Registry, nil] hooks registry shared with Engine.
    #   Engine owns the registry; KernelLoop only fires events. Accessor allows
    #   Engine to propagate its registry to an externally-created kernel (TUI path).
    attr_accessor :hooks
    attr_accessor :client
    attr_accessor :model_key

    # Run the conversation loop and return the final model response plus
    # resumable conversation state when execution stops at max_iterations.
    #
    # @param messages       [Array<Hash>, Result] conversation so far ({role:, content:})
    #                                           or a previous Result to resume
    # @param max_iterations [Integer]            safety cap on tool-call rounds
    # @param on_stream_event [Proc, nil]         optional callback for generation events
    # @param cancel_controller [Client::CancellationController, nil] optional cancellation source
    # @param model_name [String, nil]            optional per-run model override
    # @param max_tool_output_chars [Integer, nil] per-output char cap for the
    #   :tool_call_completed event's `output:` (nil → env/DEFAULT_MAX_TOOL_OUTPUT_CHARS)
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
      @profile = ModelProfile.from_model_name(resolved_model_name) unless @profile_explicit

      conversation = prepare_conversation(messages)
      context_state = initial_context_status_state(conversation)
      exhausted = false
      pending_tool_calls = false
      tool_activity = []
      qwen_recovery_attempts = 0
      qwen_partial_tool_call = nil
      context_status = nil
      stream_splitter = ThoughtStreamSplitter.for_profile(@profile)
      partial_assistant_buffer = +""

      effective_max_iterations = @no_interrupt ? 1000 : max_iterations
      effective_max_tool_output_chars = resolve_output_char_cap(max_tool_output_chars)
      effective_max_iterations.times do |iteration_index|
        inject_pending_input!(conversation, pending_input, on_stream_event, iteration_index + 1)
        prompt = Prompt.format(conversation, profile: @profile)
        context_status = emit_context_status_event(on_stream_event, prompt, iteration_index: iteration_index, state: context_state) || context_status
        emit_stream_event(on_stream_event, type: :generation_started, iteration: iteration_index + 1)
        # Fire :before_generation hook
        gen_event = { type: :before_generation, iteration: iteration_index + 1 }
        fire_hook(:before_generation, gen_event) if @hooks
        response = @client.complete(
          prompt,
          **complete_kwargs(
            cancel_controller: cancel_controller,
            model_name: resolved_model_name,
            on_chunk: lambda { |chunk|
              capture_server_usage(chunk[:payload], context_state)
              partial_assistant_buffer << stream_splitter.feed(chunk[:content])[:text]
              if on_stream_event
                emit_stream_event(
                  on_stream_event,
                  type: :generation_chunk,
                  iteration: iteration_index + 1,
                  content: chunk[:content],
                  payload: chunk[:payload]
                )
              end
            },
            on_retry: (on_stream_event ? lambda { |retry_event|
              emit_stream_event(
                on_stream_event,
                {
                  type: :generation_retrying,
                  iteration: iteration_index + 1
                }.merge(retry_event)
              )
            } : nil)
          )
        )
        emit_stream_event(
          on_stream_event,
          type: :generation_completed,
          iteration: iteration_index + 1,
          content_length: response.to_s.length
        )
        verbose_log("── LLM response ──\n#{response}\n──────────────────")
        # Fire :after_generation hook (after LLM returns, before tool parse)
        after_gen_event = { type: :after_generation, iteration: iteration_index + 1, response: response }
        fire_hook(:after_generation, after_gen_event) if @hooks
        conversation << { role: "model", content: response }

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
          unless inject_pending_input!(conversation, pending_input, on_stream_event, iteration_index + 1)
            break
          end
          # Queued steering keeps the turn going: loop again so the model
          # answers the injected message instead of stopping here.
          next
        end

        qwen_recovery_attempts = 0
        qwen_partial_tool_call = nil

        emit_stream_event(on_stream_event, type: :tool_dispatch_started, iteration: iteration_index + 1, call_count: calls.length)
        results = calls.map.with_index do |call, call_index|
          emit_stream_event(
            on_stream_event,
            type: :tool_call_started,
            iteration: iteration_index + 1,
            call_count: calls.length,
            call_index: call_index + 1,
            tool: call[:name],
            call: call.dup,
            params: tool_activity_params(call[:name], call)
          )
          # Fire :before_tool_call hook (before tool dispatch, can mutate params or veto)
          # Veto protocol (minimal guardrail): a hook may set event[:blocked]=true with optional
          # event[:block_reason]="..." to prevent dispatch. Only this hook supports veto; other
          # hooks ignore :blocked. When blocked, we synthesize an error output without calling dispatch.
          before_tool_event = { type: :before_tool_call, iteration: iteration_index + 1, call: call.dup, params: tool_activity_params(call[:name], call), blocked: false, block_reason: nil }
          fire_hook(:before_tool_call, before_tool_event) if @hooks
          dispatch_result = if before_tool_event[:blocked]
                              reason = before_tool_event[:block_reason].to_s.strip
                              reason = "blocked by hook" if reason.empty?
                              synthetic = "[#{call[:name]}] Error: blocked by guardrail: #{reason}"
                              { output: synthetic, activity: tool_activity_event(call[:name], call, synthetic).merge(status: "blocked") }
                            else
                              dispatch(before_tool_event[:call])
                            end
          activity = dispatch_result[:activity]
          tool_activity << activity
          output_truncated = false
          completed_output = dispatch_result[:output]
          if effective_max_tool_output_chars && completed_output.length > effective_max_tool_output_chars
            output_truncated = true
            completed_output = completed_output[0, effective_max_tool_output_chars]
          end
          # Fire :after_tool_call hook (after tool execution, before result injection)
          after_tool_event = { type: :after_tool_call, iteration: iteration_index + 1, tool: call[:name], output: completed_output }
          fire_hook(:after_tool_call, after_tool_event) if @hooks
          emit_stream_event(
            on_stream_event,
            type: :tool_call_completed,
            iteration: iteration_index + 1,
            call_count: calls.length,
            call_index: call_index + 1,
            tool: call[:name],
            output: completed_output,
            output_truncated: output_truncated,
            activity: activity
          )
          dispatch_result[:output]
        end.join("\n\n---\n\n")
        emit_stream_event(on_stream_event, type: :tool_dispatch_completed, iteration: iteration_index + 1, call_count: calls.length)
        conversation << { role: "tool_response", content: results }
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

      Result.new(
        output: PromptLiteralGuard.restore(strip_thought_blocks(last_model_content(conversation)), profile: @profile),
        conversation: duplicate_conversation(conversation),
        exhausted: exhausted,
        pending_tool_calls: pending_tool_calls,
        tool_activity: tool_activity,
        canceled: false,
        cancellation_reason: nil,
        context_status: context_status
      )
    end

    def sync_profile_from_model!(model_name)
      @profile_explicit = false
      @profile = ModelProfile.from_model_name(model_name)
    end

    def sync_model_key!(key)
      @model_key = key
    end

    private

    def emit_stream_event(callback, event)
      callback&.call(event)
    rescue StandardError
      nil
    end

    # Drain the pending input queue (if any) and, when messages are waiting,
    # append them as ONE merged user message at the conversation tail and emit
    # :pending_input_merged. Tail-append only: head mutation would invalidate
    # the server-side prefix KV cache. Returns true when a message was injected.
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
      emit_stream_event(
        on_stream_event,
        type: :pending_input_merged,
        iteration: iteration,
        count: lines.length,
        content: content
      )
      true
    end

    # ── Hook dispatch helper ───────────────────────────────────────────────────

    # Fire a named hook on the registry (if present).
    # Hooks are dispatched synchronously; the event hash is passed by reference
    # so hooks can mutate fields (e.g. :before_tool_call can modify :call).
    def fire_hook(name, event)
      return unless @hooks
      @hooks.fire(name, event)
    rescue StandardError
      # A failing hook must not break the turn.
    end

    # Coerce a value to boolean — handles true/false, nil, and string "true"/"false".
    def truthy?(val)
      return true  if val == true
      return false if val == false || val.nil?
      val.to_s.strip.downcase == "true"
    end

    # ── Output char cap resolution ─────────────────────────────────────────────

    # Resolve the per-output character cap for the emitted tool call events.
    #
    # Precedence: an explicit override wins, then the SAMAGOTCHI_MAX_TOOL_OUTPUT_CHARS
    # env var, then DEFAULT_MAX_TOOL_OUTPUT_CHARS. A non-positive value falls back
    # to the default (there is intentionally no "unlimited" — live UIs get a
    # bounded `output:` plus a truthful `output_truncated:` flag).
    def resolve_output_char_cap(override)
      cfg_val = begin
        v = Samagotchi::Config.get("max_tool_output_chars") rescue nil
        v.to_i if v
      end
      value = override || cfg_val || ENV[TOOL_OUTPUT_CHARS_ENV]
      parsed = value.to_i
      parsed.positive? ? parsed : DEFAULT_MAX_TOOL_OUTPUT_CHARS
    end

    def complete_kwargs(cancel_controller:, model_name: nil, on_chunk: nil, on_retry: nil)
      kwargs = {}
      kwargs[:on_chunk] = on_chunk if on_chunk
      kwargs[:on_retry] = on_retry if on_retry && client_supports_keyword?(:on_retry)
      kwargs[:cancel_controller] = cancel_controller if cancel_controller && client_supports_keyword?(:cancel_controller)
      kwargs[:stop] = @profile.stop_sequences if client_supports_keyword?(:stop)
      n_predict = completion_n_predict
      kwargs[:n_predict] = n_predict if n_predict && client_supports_keyword?(:n_predict)
      resolved_model_name = completion_model_name(model_name)
      kwargs[:model] = resolved_model_name if resolved_model_name && client_supports_keyword?(:model)
      kwargs
    end

    def completion_n_predict
      v = Samagotchi::Config.get("default.n_predict") rescue nil
      v.to_i if v && v.to_i.positive?
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

    def verbose_log(message)
      tagged = "[model: #{@current_model_name}] #{message}"
      @debug_log&.write(tagged)
      return unless @verbose

      $stderr.puts "\n[verbose] #{tagged}"
    end

    # Estimate context usage for this iteration's prompt and, when the emit
    # gate fires, surface it to stream consumers as a :context_status event.
    # The model no longer receives the telemetry (it used to be injected as a
    # synthetic system message); the returned {est_pct:, bucket:} hash feeds
    # the Result's context_status for UI status lines (nil when not emitted).
    def emit_context_status_event(on_stream_event, prompt, iteration_index:, state:)
      return nil unless context_status_enabled?

      usage = estimate_context_usage(prompt, server_usage: state[:server_usage])
      bucket = context_status_bucket(usage[:estimated_pct])
      emit_status = should_emit_context_status?(state: state, bucket: bucket, iteration_index: iteration_index)
      state[:last_bucket] = bucket
      return nil unless emit_status

      status_message = context_status_message(usage: usage, bucket: bucket, source: usage[:source])
      emit_stream_event(
        on_stream_event,
        type: :context_status,
        iteration: iteration_index + 1,
        status: status_message,
        usage: usage,
        bucket: bucket,
        source: usage[:source]
      )
      verbose_log("── context status ──\n#{status_message}\n──────────────────")
      { est_pct: usage[:estimated_pct], bucket: bucket }
    end

    def capture_server_usage(payload, state)
      normalized = ContextUsage.normalize(payload)
      state[:server_usage] = normalized if normalized
    end

    def initial_context_status_state(conversation)
      { last_bucket: extract_last_context_status_bucket(conversation) }
    end

    def extract_last_context_status_bucket(conversation)
      message = conversation.reverse.find do |entry|
        entry[:role] == "system" && entry[:content].to_s.start_with?(CONTEXT_STATUS_PREFIX)
      end
      return nil unless message

      match = message[:content].match(/\bbucket=([a-z0-9_]+)/)
      match && match[1]
    end

    def context_status_enabled?
      cfg = begin Samagotchi::Config.get("context.status") rescue nil end
      unless cfg.nil?
        return !!cfg
      end
      value = ENV[CONTEXT_STATUS_ENABLED_ENV]
      return true if value.nil?

      !(value == "0" || value.casecmp?("false"))
    end

    def estimate_context_usage(prompt, server_usage: nil)
      if server_usage && server_usage[:prompt_tokens]
        window_tokens = server_usage[:context_window_tokens] || context_window_tokens
        estimated_used_tokens = server_usage[:prompt_tokens]
        estimated_remaining_tokens = [window_tokens - estimated_used_tokens, 0].max
        estimated_pct = (estimated_used_tokens.to_f / window_tokens) * 100.0

        return {
          window_tokens: window_tokens,
          estimated_used_tokens: estimated_used_tokens,
          estimated_remaining_tokens: estimated_remaining_tokens,
          estimated_pct: estimated_pct,
          source: "server"
        }
      end

      window_tokens = context_window_tokens
      estimated_used_tokens = (prompt.length / context_chars_per_token).ceil
      estimated_remaining_tokens = [window_tokens - estimated_used_tokens, 0].max
      estimated_pct = (estimated_used_tokens.to_f / window_tokens) * 100.0

      {
        window_tokens: window_tokens,
        estimated_used_tokens: estimated_used_tokens,
        estimated_remaining_tokens: estimated_remaining_tokens,
        estimated_pct: estimated_pct,
        source: "estimate"
      }
    end

    def context_window_tokens
      cfg = begin Samagotchi::Config.get("context.window_tokens") rescue nil end
      if cfg && cfg.to_i.positive?
        v = cfg.to_i
        return v.positive? ? v : DEFAULT_CONTEXT_WINDOW_TOKENS
      end
      value = ENV.fetch(CONTEXT_WINDOW_TOKENS_ENV, DEFAULT_CONTEXT_WINDOW_TOKENS.to_s).to_i
      value.positive? ? value : DEFAULT_CONTEXT_WINDOW_TOKENS
    end

    def context_chars_per_token
      cfg = begin Samagotchi::Config.get("context.chars_per_token") rescue nil end
      if cfg && cfg.to_f.positive?
        v = cfg.to_f
        return v.positive? ? v : DEFAULT_CONTEXT_CHARS_PER_TOKEN
      end
      value = ENV.fetch(CONTEXT_CHARS_PER_TOKEN_ENV, DEFAULT_CONTEXT_CHARS_PER_TOKEN.to_s).to_f
      value.positive? ? value : DEFAULT_CONTEXT_CHARS_PER_TOKEN
    end

    def context_status_thresholds
      cfg = begin Samagotchi::Config.get("context.status_thresholds") rescue nil end
      raw = cfg && !cfg.to_s.strip.empty? ? cfg.to_s : ENV.fetch(CONTEXT_THRESHOLDS_ENV, DEFAULT_CONTEXT_THRESHOLDS.join(","))
      parsed = raw.split(",").map { |value| value.strip.to_i }.select { |value| value.between?(1, 99) }.uniq.sort
      parsed.empty? ? DEFAULT_CONTEXT_THRESHOLDS : parsed
    end

    def context_status_cadence
      cfg = begin Samagotchi::Config.get("context.status_cadence") rescue nil end
      if !cfg.nil?
        v = cfg.to_i
        return [v, 0].max
      end
      value = ENV.fetch(CONTEXT_CADENCE_ENV, DEFAULT_CONTEXT_CADENCE.to_s).to_i
      [value, 0].max
    end

    def context_status_bucket(estimated_pct)
      thresholds = context_status_thresholds
      bucket = "under#{thresholds.first}"
      thresholds.each do |threshold|
        bucket = "#{threshold}plus" if estimated_pct >= threshold
      end
      bucket
    end

    def should_emit_context_status?(state:, bucket:, iteration_index:)
      last_bucket = state[:last_bucket]
      below_threshold_bucket = "under#{context_status_thresholds.first}"
      bucket_changed = if last_bucket.nil?
                         bucket != below_threshold_bucket
                       else
                         bucket != last_bucket
                       end

      cadence = context_status_cadence
      cadence_due = cadence.positive? && ((iteration_index + 1) % cadence).zero?
      bucket_changed || cadence_due
    end

    def context_status_message(usage:, bucket:, source:)
      format(
        "%<prefix>s window_tokens=%<window>d est_used_tokens=%<used>d est_remaining_tokens=%<remaining>d est_pct=%<pct>.1f bucket=%<bucket>s thresholds=%<thresholds>s src=%<src>s guidance=%<guidance>s",
        prefix: CONTEXT_STATUS_PREFIX,
        window: usage[:window_tokens],
        used: usage[:estimated_used_tokens],
        remaining: usage[:estimated_remaining_tokens],
        pct: usage[:estimated_pct],
        bucket: bucket,
        thresholds: context_status_thresholds.join(","),
        src: source,
        guidance: context_status_guidance(bucket)
      )
    end

    def context_status_guidance(bucket)
      case bucket
      when "under20", "20plus"
        "context healthy — proceed normally"
      when "40plus"
        "context moderate — prefer targeted and range reads over full-file dumps"
      when "60plus"
        "context elevated — be concise, prefer range reads, avoid re-reading large files"
      when "80plus"
        "context critical — summarize aggressively, avoid large outputs, delegate broad work to subagents"
      else
        "context healthy — proceed normally"
      end
    end

    # Parse tool calls from raw model output using the active profile's
    # ToolCallParser strategy (Gemma 4 or Qwen 3.6).
    # Thought content is intentionally left intact while a tool-call turn is in
    # progress to preserve same-turn reasoning context between tool calls.
    def parse_tool_calls(text)
      parser.parse(text.to_s)
    end

    # Public wrapper so other loops (e.g. the ruby_llm backend) can strip
    # per-profile thought blocks from finished model text without duplicating the
    # Gemma 4 / Qwen 3.6 logic. Mirrors the native loop's "strip before deciding
    # whether the model called a tool / returning the final answer".
    def strip_model_thought(text)
      strip_thought_blocks(text)
    end

    # Per-profile parse strategy. Rebuilt when the active profile changes
    # (the profile may be re-inferred per run when not explicitly pinned).
    # Public so other loops (and specs) can reach the active profile's parser.
    public
    def parser
      @parser = ToolCallParser.for_profile(@profile) if @parser_profile != @profile
      @parser_profile = @profile
      @parser
    end
    private

    # Remove thought blocks from model output. The format depends on profile
    # (Gemma 4 <|think|>/channel blocks vs Qwen 3.6 literal think tokens);
    # the per-profile logic lives in ToolCallParser.
    def strip_thought_blocks(text)
      parser.strip_thought(text)
    end

    def sanitize_history(messages)
      messages.map do |m|
        if m[:role] == "model"
          { role: m[:role], content: strip_thought_blocks(m[:content].to_s) }
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

    def last_model_content(conversation)
      message = conversation.reverse.find { |entry| entry[:role] == "model" }
      message ? message[:content].to_s : ""
    end

    def tool_response_turn?(message)
      message && message[:role] == "tool_response"
    end

    # Public entry point for executing an ALREADY-NORMALIZED internal tool call
    # (the {name:, content:, path:, scope:, …} shape).
    #
    # Other agentic loops — notably the ruby_llm backend's native tool-round loop
    # — need to execute tool calls through this single path so tool execution,
    # unknown-tool handling, and activity events are shared, not duplicated. Callers
    # are responsible for normalizing the provider's native call into this shape
    # first (see Samagotchi::LLM::NativeToolNormalizer); dispatch itself never
    # parses provider text.
    def dispatch_tool_call(call)
      dispatch(call)
    end

    def dispatch(call)
      tool = TOOLS.find { |t| t.name == call[:name] }
      unless tool
        available = TOOLS.map(&:name).join(", ")
        result = "Error: unknown tool '#{call[:name]}'. Available: #{available}"
        return {
          output: result,
          activity: tool_activity_event(call[:name], call, result)
        }
      end

      verbose_log("── tool call: #{call[:name]} ──\n#{call[:path] ? "path: #{call[:path]}\n" : ""}#{call[:scope] ? "scope: #{call[:scope]}\n" : ""}#{call[:content]}\n──────────────────")

      result = case call[:name]
               when Tools::MemoryRead::NAME
                 tool.call(call[:content], scope: call[:scope], model_key: @model_key)
               when Tools::MemoryWrite::NAME
                 tool.call(call[:content], path: call[:path], scope: call[:scope], description: call[:description],
                           current_model_only: truthy?(call[:current_model_only]), model_key: @model_key)
               when Tools::Write::NAME
                 tool.call(call[:content], path: call[:path])
               when Tools::Read::NAME
                 tool.call(call[:content], start_line: call[:start_line], end_line: call[:end_line])
               when Tools::Edit::NAME
                 tool.call(call[:content], path: call[:path], start_line: call[:start_line], end_line: call[:end_line])
               when Tools::TaskCreate::NAME
                 tool.call(call[:content], cwd: call[:cwd], env: call[:env])
               when Tools::TaskGet::NAME, Tools::TaskStop::NAME
                 tool.call(call[:content])
               when Tools::TaskWait::NAME
                 tool.call(
                   call[:content],
                   timeout: call[:timeout],
                   tail_lines: call[:tail_lines],
                   done_pattern: call[:done_pattern]
                 )
               when Tools::Execute::NAME
                 tool.call(call[:content], cwd: call[:cwd])
               when Tools::WebFetch::NAME
                 tool.call(call[:content])
               when Tools::RegisterReminder::NAME
                 tool.call(call[:content], reminder_store: @reminder_store, description: call[:description], interval_minutes: call[:interval_minutes])
               when Tools::CancelReminder::NAME
                 tool.call(call[:content], reminder_store: @reminder_store)
                when Tools::ListReminders::NAME
                  tool.call(call[:content], reminder_store: @reminder_store)
                when Tools::AskUserQuestion::NAME
                  handle_ask_user_question(call)
                else
                  tool.call(call[:content])
                end

      verbose_log("── tool result: #{call[:name]} ──\n#{result}\n──────────────────")
      {
        output: "[#{call[:name]}]\n#{result}",
        activity: tool_activity_event(call[:name], call, result)
      }
    rescue => e
      verbose_log("── tool error: #{call[:name]} ──\n#{e.message}\n──────────────────")
      result = "Error: #{e.message}"
      {
        output: "[#{call[:name]}] #{result}",
        activity: tool_activity_event(call[:name], call, result)
      }
    end

    def handle_ask_user_question(call)
      question = (call[:question] || call[:content]).to_s.strip
      raw_opts = call[:options]
      # Dumb-model tolerant: raw may be String JSON, Array, or malformed with brackets/quotes
      options = Samagotchi::Tools::AskUserQuestion.normalize_options_lenient(raw_opts)
      # Fallback for case where raw was String like '["a","b"]' but lenient returned [] due to edge parse, try raw string of params
      if options.empty? && raw_opts.is_a?(String)
        options = Samagotchi::Tools::AskUserQuestion.normalize_options_lenient(raw_opts.to_s)
      end
      header = call[:header].to_s.strip
      header = nil if header.empty?
      multi = call[:multi_select]
      free = call[:allow_freeform]
      # Normalize booleans from string forms (Gemma passes "true"/"false" as strings)
      multi = normalize_ask_bool(multi)
      free = normalize_ask_bool(free)

      if question.empty?
        return "Error: ask_user_question requires 'question'"
      end
      # Dumb-model tolerant: salvage single-option parse glitches, but still require at least 1
      if options.size < 1
        alt = Samagotchi::Tools::AskUserQuestion.normalize_options_lenient(call[:content].to_s) if call[:content]
        options = alt unless alt.empty?
      end
      if options.empty?
        return "Error: ask_user_question requires 2-8 options (got 0). Provide e.g. options=[\"Cats\",\"Dogs\"]"
      end
      if options.size == 1
        # Allow single-option salvage for dumb models (will still render, user can answer or provide freeform)
      elsif options.size < 2 || options.size > 8
        return "Error: ask_user_question requires 2-8 options (got #{options.size}). Provide e.g. options=[\"Cats\",\"Dogs\"]"
      end

      # If an Engine-level blocking handler is registered (TUI/Web), delegate there.
      # The handler is stored on the Engine via KernelLoop's engine reference set
      # by Engine initializer (see Engine#initialize kernel coupling). Fallback to a
      # non-blocking JSON preview so the model can still see a structured response.
      handler = nil
      if defined?(@question_handler) && @question_handler
        handler = @question_handler
      elsif instance_variable_defined?(:@engine) && @engine && @engine.respond_to?(:request_question)
        handler = proc { |payload| @engine.request_question(payload) }
      elsif instance_variable_defined?(:@kernel) && @kernel && @kernel.respond_to?(:engine) && @kernel.engine.respond_to?(:request_question)
        handler = proc { |payload| @kernel.engine.request_question(payload) }
      end
      # Also check if KernelLoop was constructed with an Engine-linked kernel that exposes request_question via injected Engine
      if handler.nil? && defined?(@engine_request_question_handler) && @engine_request_question_handler
        handler = @engine_request_question_handler
      end

      payload = {
        question: question,
        options: options,
        header: header,
        multi_select: !!multi,
        allow_freeform: !!free
      }.compact

      if handler
        begin
          result = handler.call(payload)
          return result.to_s
        rescue => e
          return "Error: ask_user_question handler failed: #{e.message}"
        end
      end

      # Headless fallback: return JSON so model sees structured options and can
      # fallback to plain text qualification.
      JSON.pretty_generate(payload)
    end

    def normalize_ask_bool(v)
      return nil if v.nil?
      return v if v == true || v == false

      s = v.to_s.strip.downcase
      return true if %w[1 true yes on].include?(s)
      return false if %w[0 false no off].include?(s)

      nil
    end

    def tool_activity_event(tool_name, call, result)
      {
        action: tool_activity_action(tool_name),
        tool: tool_name,
        params: tool_activity_params(tool_name, call),
        status: tool_activity_status(result)
      }
    end

    def tool_activity_action(tool_name)
      case tool_name
      when Tools::Execute::NAME then "running command"
      when Tools::Read::NAME then "reading file"
      when Tools::Write::NAME then "writing file"
      when Tools::Edit::NAME then "editing file"
      when Tools::MemoryRead::NAME then "reading memory"
      when Tools::MemoryWrite::NAME then "saving memory"
      when Tools::TaskCreate::NAME then "starting background task"
      when Tools::TaskGet::NAME then "checking task"
      when Tools::TaskList::NAME then "listing tasks"
      when Tools::TaskStop::NAME then "stopping task"
      when Tools::TaskWait::NAME then "waiting for task"
      when Tools::WebFetch::NAME then "fetching URL"
      when Tools::AskUserQuestion::NAME then "asking user"
      else "calling tool"
      end
    end

    def tool_activity_status(result)
      result.to_s.start_with?("Error:") ? "error" : "ok"
    end

    def tool_activity_params(tool_name, call)
      case tool_name
      when Tools::Execute::NAME
        "command=#{preview_tool_param(call[:content])}"
      when Tools::Read::NAME
        parts = ["path=#{preview_tool_param(call[:content])}"]
        range = format_line_range(call)
        parts << "lines=#{range}" if range
        parts.join(" ")
      when Tools::Write::NAME
        "path=#{preview_tool_param(call[:path])}"
      when Tools::Edit::NAME
        parts = ["path=#{preview_tool_param(call[:path])}"]
        range = format_line_range(call)
        parts << "lines=#{range}" if range
        parts.join(" ")
      when Tools::MemoryRead::NAME
        parts = []
        name = call[:content].to_s.strip
        parts << "name=#{preview_tool_param(name)}" unless name.empty?
        scope = call[:scope].to_s.strip
        parts << "scope=#{preview_tool_param(scope)}" unless scope.empty?
        parts.join(" ")
      when Tools::MemoryWrite::NAME
        parts = []
        path = call[:path].to_s.strip
        parts << "name=#{preview_tool_param(path)}" unless path.empty?
        scope = call[:scope].to_s.strip
        parts << "scope=#{preview_tool_param(scope)}" unless scope.empty?
        desc = call[:description].to_s.strip
        parts << "description=#{preview_tool_param(desc)}" unless desc.empty?
        parts.join(" ")
      when Tools::TaskCreate::NAME
        parts = ["command=#{preview_tool_param(call[:content])}"]
        cwd = call[:cwd].to_s.strip
        parts << "cwd=#{preview_tool_param(cwd)}" unless cwd.empty?
        env = call[:env].to_s.strip
        parts << "env=#{preview_tool_param(env)}" unless env.empty?
        parts.join(" ")
      when Tools::TaskGet::NAME, Tools::TaskStop::NAME
        "id=#{preview_tool_param(call[:content])}"
      when Tools::TaskWait::NAME
        parts = ["id=#{preview_tool_param(call[:content])}"]
        timeout = call[:timeout].to_s.strip
        tail_lines = call[:tail_lines].to_s.strip
        done_pattern = call[:done_pattern].to_s.strip
        parts << "timeout=#{preview_tool_param(timeout)}" unless timeout.empty?
        parts << "tail_lines=#{preview_tool_param(tail_lines)}" unless tail_lines.empty?
        parts << "done_pattern=#{preview_tool_param(done_pattern)}" unless done_pattern.empty?
        parts.join(" ")
      when Tools::TaskList::NAME
        nil
      when Tools::WebFetch::NAME
        "url=#{preview_tool_param(call[:content])}"
      when Tools::AskUserQuestion::NAME
        parts = ["question=#{preview_tool_param(call[:question] || call[:content])}"]
        opts = call[:options]
        parts << "options=#{preview_tool_param(Array(opts).join(","))}" if opts && !Array(opts).empty?
        parts.join(" ")
      else
        nil
      end
    end

    def format_line_range(call)
      start_line = call[:start_line].to_s.strip
      end_line = call[:end_line].to_s.strip
      return nil if start_line.empty? && end_line.empty?

      "#{start_line.empty? ? "?" : start_line}-#{end_line.empty? ? "?" : end_line}"
    end

    def preview_tool_param(value)
      text = value.to_s.gsub(/\s+/, " ").strip
      return '""' if text.empty?

      if text.length > TOOL_ACTIVITY_PREVIEW_LIMIT
        text = "#{text[0, TOOL_ACTIVITY_PREVIEW_LIMIT - 1]}…"
      end
      text.inspect
    end
  end
end
