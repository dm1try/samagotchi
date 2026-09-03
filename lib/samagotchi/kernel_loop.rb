# frozen_string_literal: true

require_relative "model_profile"
require_relative "context_usage"
require_relative "prompt"
require_relative "prompt_literal_guard"
require_relative "client"
require_relative "debug_log"
require_relative "hooks"
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
    Result = Struct.new(:output, :conversation, :exhausted, :pending_tool_calls, :tool_activity, :canceled, :cancellation_reason, keyword_init: true) do
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
      Tools::ImageRead
    ].freeze

    # ── Gemma 4 tool-call constants (canonical model call format) ─────────────
    # <|tool_call>call:NAME{params}<tool_call|>  — model's request to use a tool.
    TOOL_CALL_OPEN      = "<|tool_call>"
    TOOL_CALL_CLOSE     = "<tool_call|>"
    TOOL_CALL_BODY_RE   = /\Acall:([a-z_]{1,50})\{/

    # ── Gemma 4 string delimiter ──────────────────────────────────────────────
    # Gemma 4 uses <|"|> as a delimiter token for all string values in its
    # structured data blocks (function calls, responses, etc.).  The harness
    # must NOT mistake the <| in this token for a real control-token boundary,
    # and must strip/translate these delimiters when extracting parameter values.
    GEMMA_STRING_DELIM = '<|"|>'

    # ── Gemma 4 thought-channel stripping (canonical) ─────────────────────────
    # <|think|> opens a private reasoning block; it ends at the next <| control
    # token (that is not the Gemma string delimiter) or end of string.  Both
    # delimiters are used as plain strings (no regex) to avoid any backtracking
    # risk on adversarial input.
    THOUGHT_OPEN        = "<|think|>"
    THOUGHT_CHANNEL_OPEN  = "<|channel>thought"
    THOUGHT_CHANNEL_CLOSE = "<channel|>"
    CONTROL_TOKEN_START = "<|"

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

    def initialize(client: nil, verbose: false, log_file: nil, debug_log: nil, profile: nil, model_name: nil, no_interrupt: false, hooks: nil, reminder_store: nil)
      @client = client || Client.new
      @verbose = verbose
      @debug_log = debug_log || DebugLog.new(path: log_file)
      @profile_explicit = !profile.nil?
      @no_interrupt = no_interrupt
      resolved_model_name = ModelProfile.required_model_name(model_name)
      @profile = profile ? ModelProfile.normalize(profile) : ModelProfile.from_model_name(resolved_model_name)
      @hooks = hooks
      @reminder_store = reminder_store
    end

    # @return [ReminderStore, nil] the reminder store for inspection (used by
    #   Engine to share the same store with the KernelLoop when TerminalUI
    #   creates both).
    attr_reader :reminder_store

    # @return [Samagotchi::Hooks::Registry, nil] hooks registry shared with Engine.
    #   Engine owns the registry; KernelLoop only fires events. Accessor allows
    #   Engine to propagate its registry to an externally-created kernel (TUI path).
    attr_accessor :hooks

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
    # @return [Result] final visible response with continuation metadata
    def run(messages, max_iterations: 100, on_stream_event: nil, cancel_controller: nil, model_name: nil, max_tool_output_chars: nil)
      resolved_model_name = completion_model_name(model_name)
      @profile = ModelProfile.from_model_name(resolved_model_name) unless @profile_explicit

      conversation = prepare_conversation(messages)
      context_state = initial_context_status_state(conversation)
      exhausted = false
      pending_tool_calls = false
      tool_activity = []
      qwen_recovery_attempts = 0
      qwen_partial_tool_call = nil

      effective_max_iterations = @no_interrupt ? 1000 : max_iterations
      effective_max_tool_output_chars = resolve_output_char_cap(max_tool_output_chars)
      effective_max_iterations.times do |iteration_index|
        prompt = prompt_with_context_status(conversation, iteration_index: iteration_index, state: context_state)
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

        qwen_parse_input = qwen_parse_input(response, qwen_partial_tool_call)
        calls = parse_tool_calls(qwen_parse_input).map do |call|
          PromptLiteralGuard.restore_call(call, profile: @profile)
        end
        qwen_incomplete_tool_call = qwen_profile? && qwen_incomplete_tool_call?(qwen_parse_input)

        if qwen_incomplete_tool_call
          qwen_partial_tool_call = qwen_unterminated_tool_call_fragment(qwen_parse_input)
        else
          qwen_partial_tool_call = nil
        end

        if calls.empty?
          if qwen_incomplete_tool_call && qwen_recovery_attempts < QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_LIMIT
            qwen_recovery_attempts += 1
            conversation << { role: "user", content: QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_PROMPT, preserve_literals: true }
            pending_tool_calls = false
            next
          end

          pending_tool_calls = false
          break
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
          # Fire :before_tool_call hook (before tool dispatch, can mutate params)
          before_tool_event = { type: :before_tool_call, iteration: iteration_index + 1, call: call.dup, params: tool_activity_params(call[:name], call) }
          fire_hook(:before_tool_call, before_tool_event) if @hooks
          dispatch_result = dispatch(before_tool_event[:call])
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
        return cancelled_result(conversation, tool_activity: tool_activity, reason: e.reason)
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
        cancellation_reason: nil
      )
    end

    def sync_profile_from_model!(model_name)
      @profile_explicit = false
      @profile = ModelProfile.from_model_name(model_name)
    end

    private

    def emit_stream_event(callback, event)
      callback&.call(event)
    rescue StandardError
      nil
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

    # ── Output char cap resolution ─────────────────────────────────────────────

    # Resolve the per-output character cap for the emitted tool call events.
    #
    # Precedence: an explicit override wins, then the SAMAGOTCHI_MAX_TOOL_OUTPUT_CHARS
    # env var, then DEFAULT_MAX_TOOL_OUTPUT_CHARS. A non-positive value falls back
    # to the default (there is intentionally no "unlimited" — live UIs get a
    # bounded `output:` plus a truthful `output_truncated:` flag).
    def resolve_output_char_cap(override)
      value = override || ENV[TOOL_OUTPUT_CHARS_ENV]
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
      env_value = ENV["SAMAGOTCHI_N_PREDICT"] || ENV["SAMAGOTCHI_MAX_TOKENS"]
      if env_value && !env_value.empty?
        parsed = env_value.to_i
        return parsed if parsed.positive?
      end

      # Qwen often emits hidden reasoning before the final answer; a larger
      # budget prevents user-visible truncation in assist mode.
      return 1024 if @profile.name == "qwen36"

      nil
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

    def cancelled_result(conversation, tool_activity:, reason:)
      Result.new(
        output: "",
        conversation: duplicate_conversation(conversation),
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: tool_activity,
        canceled: true,
        cancellation_reason: reason
      )
    end

    def verbose_log(message)
      @debug_log&.write(message)
      return unless @verbose

      $stderr.puts "\n[verbose] #{message}"
    end

    def prompt_with_context_status(conversation, iteration_index:, state:)
      prompt = Prompt.format(conversation, profile: @profile)
      return prompt unless context_status_enabled?

      usage = estimate_context_usage(prompt, server_usage: state[:server_usage])
      bucket = context_status_bucket(usage[:estimated_pct])
      emit_status = should_emit_context_status?(state: state, bucket: bucket, iteration_index: iteration_index)
      state[:last_bucket] = bucket
      return prompt unless emit_status

      status_message = context_status_message(usage: usage, bucket: bucket, source: usage[:source])
      conversation << { role: "system", content: status_message }
      verbose_log("── context status ──\n#{status_message}\n──────────────────")
      Prompt.format(conversation, profile: @profile)
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
      value = ENV.fetch(CONTEXT_WINDOW_TOKENS_ENV, DEFAULT_CONTEXT_WINDOW_TOKENS.to_s).to_i
      value.positive? ? value : DEFAULT_CONTEXT_WINDOW_TOKENS
    end

    def context_chars_per_token
      value = ENV.fetch(CONTEXT_CHARS_PER_TOKEN_ENV, DEFAULT_CONTEXT_CHARS_PER_TOKEN.to_s).to_f
      value.positive? ? value : DEFAULT_CONTEXT_CHARS_PER_TOKEN
    end

    def context_status_thresholds
      raw = ENV.fetch(CONTEXT_THRESHOLDS_ENV, DEFAULT_CONTEXT_THRESHOLDS.join(","))
      parsed = raw.split(",").map { |value| value.strip.to_i }.select { |value| value.between?(1, 99) }.uniq.sort
      parsed.empty? ? DEFAULT_CONTEXT_THRESHOLDS : parsed
    end

    def context_status_cadence
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

    # Parse tool calls from raw model output.
    # Dispatches to the appropriate parser based on the active profile.
    # Falls back to alternate format if primary parser finds nothing.
    # Thought content is intentionally left intact while a tool-call turn is in
    # progress to preserve same-turn reasoning context between tool calls.
    def parse_tool_calls(text)
      case @profile.name
      when "qwen36"
        parse_qwen_tool_calls(text)
      else
        parse_native_tool_calls(text)
      end
    end

    # Public wrapper so other loops (e.g. the ruby_llm backend) can strip
    # per-profile thought blocks from finished model text without duplicating the
    # Gemma 4 / Qwen 3.6 logic. Mirrors the native loop's "strip before deciding
    # whether the model called a tool / returning the final answer".
    def strip_model_thought(text)
      strip_thought_blocks(text)
    end

    # Remove thought blocks from model output.
    # Format depends on profile:
    #   - Gemma 4: <|think|>CONTENT (ends at next real <| token) and <|channel>thought...
    #   - Qwen 3.6: <think>CONTENT</think>
    def strip_thought_blocks(text)
      if @profile.name == "qwen36"
        strip_qwen_thought_blocks(text)
      else
        strip_gemma_thought_blocks(text)
      end
    end

    # Remove Qwen 3.6 <think>...</think> blocks from text.
    # Handles:
    #   - Complete think blocks: <think>CONTENT</think>
    #   - Incomplete opening tags: <think> without </think>
    #   - Orphaned closing tags: </think> without <think>
    def strip_qwen_thought_blocks(text)
      # Remove all complete <think>...</think> blocks (including any leading/trailing whitespace)
      result = text.gsub(/<think>.*?<\/think>/m, '')
      # Remove any stray opening tags
      result = result.gsub(/<think>.*?(?=\n|$)/m, '')
      # Remove any orphaned closing tags (and preceding whitespace on same line if it's all whitespace)
      result = result.gsub(/^\s*<\/think>\s*\n?/m, '')
      # Clean up any extra blank lines that may have been left behind
      result.gsub(/\n\n+/, "\n")
    end

    # Remove Gemma 4 thought blocks from text.
    # <|think|>CONTENT — ends at the next real <| control token
    # (skipping any <|"|> Gemma string-delimiter tokens) or EOS.
    # <|channel>thought......</channel|> — channel format blocks
    def strip_gemma_thought_blocks(text)
      result = text

      # Canonical format: strip from <|think|> to the next real <| (exclusive) or EOS
      while (open_pos = result.index(THOUGHT_OPEN))
        body_start = open_pos + THOUGHT_OPEN.length
        close_pos  = next_real_control_token(result, body_start)
        result = if close_pos
                   result[0...open_pos] + result[close_pos..]
                 else
                   result[0...open_pos]
                 end
      end

      # Emitted thought-channel format: strip from <|channel>thought to the
      # corresponding closing tag, or EOS if the close is missing.
      while (open_pos = result.index(THOUGHT_CHANNEL_OPEN))
        close_pos = result.index(THOUGHT_CHANNEL_CLOSE, open_pos)
        result = if close_pos
                   result[0...open_pos] + result[close_pos + THOUGHT_CHANNEL_CLOSE.length..]
                 else
                   result[0...open_pos]
                 end
      end

      result
    end

    # Parse canonical Gemma 4 tool calls:
    #   <|tool_call>call:NAME{params}<tool_call|>
    # Uses String#index for outer delimiters (no backtracking risk).
    def parse_native_tool_calls(text)
      results = []

      pos = 0
      while (open_pos = text.index(TOOL_CALL_OPEN, pos))
        body_start = open_pos + TOOL_CALL_OPEN.length
        close_pos  = text.index(TOOL_CALL_CLOSE, body_start)
        break unless close_pos

        body = text[body_start...close_pos]
        if (m = TOOL_CALL_BODY_RE.match(body))
          name       = m[1]
          params_raw = body[m.end(0)..]
          params_raw = params_raw[0..-2] if params_raw.end_with?("}")
          results << native_call(name, params_raw.strip)
        end
        pos = close_pos + TOOL_CALL_CLOSE.length
      end

      results
    end

    def qwen_parse_input(response, partial_fragment)
      return response.to_s unless qwen_profile?
      return response.to_s unless partial_fragment

      partial_fragment + response.to_s
    end

    def qwen_profile?
      @profile.name == "qwen36"
    end

    # Returns true when a <tool_call> block is opened but not closed.
    def qwen_incomplete_tool_call?(text)
      open_tag = "<tool_call>"
      close_tag = "</tool_call>"
      pos = 0

      while (open_pos = text.index(open_tag, pos))
        body_start = open_pos + open_tag.length
        close_pos = text.index(close_tag, body_start)
        return true unless close_pos

        pos = close_pos + close_tag.length
      end

      false
    end

    # Returns the suffix starting at the first unterminated <tool_call>.
    def qwen_unterminated_tool_call_fragment(text)
      open_tag = "<tool_call>"
      close_tag = "</tool_call>"
      pos = 0

      while (open_pos = text.index(open_tag, pos))
        body_start = open_pos + open_tag.length
        close_pos = text.index(close_tag, body_start)
        return text[open_pos..] unless close_pos

        pos = close_pos + close_tag.length
      end

      nil
    end

    # Parse Qwen 3.6 tool calls:
    #   <tool_call><function=NAME><parameter=KEY>VALUE</parameter></function></tool_call>
    # Also recovers from a common malformed variant where the function tag is
    # missing its closing ">" before the next XML tag, and from logged
    # arg_key/arg_value pairs emitted by some model responses.
    # Uses simple string index matching to find opening/closing tags.
    def parse_qwen_tool_calls(text)
      results = []

      pos = 0
      tool_open = "<tool_call>"
      tool_close = "</tool_call>"

      while (open_pos = text.index(tool_open, pos))
        body_start = open_pos + tool_open.length
        close_pos  = text.index(tool_close, body_start)
        break unless close_pos

        body = text[body_start...close_pos]
        if (name = qwen_function_name(body))
          params = qwen_params(body)
          results << qwen_call_to_internal(name, params)
        end
        pos = close_pos + tool_close.length
      end

      results
    end

    def qwen_function_name(body)
      match = body.match(/<function=([a-z0-9_]+)(?:>|(?=<)|$)/i)
      match && match[1].to_s.downcase
    end

    def qwen_params(body)
      params = {}

      body.scan(/<parameter=(\w+)>(.*?)<\/parameter>/m) do |key, value|
        params[key.to_s.downcase] = trim_tag_newline(value)
      end

      body.scan(/<arg_key>(.*?)<\/arg_key>\s*<arg_value>(.*?)<\/arg_value>/m) do |key, value|
        params[key.to_s.downcase.strip] = trim_tag_newline(value)
      end

      params
    end

    # Models often place the value on its own line inside the tag pair, per the
    # documented hint template; strip only that one formatting newline on each
    # side so it isn't mistaken for actual leading/trailing content.
    def trim_tag_newline(value)
      value.sub(/\A\r?\n/, "").sub(/\r?\n\z/, "")
    end

    # Convert a Qwen tool call to internal format.
    # Qwen uses XML parameters while internal format uses {name:, content:, path:, scope:}.
    def qwen_call_to_internal(name, params)
      case name
      when Tools::Execute::NAME
        { name: name, content: qwen_param_value(params, "command"), path: nil, scope: nil }
      when Tools::Read::NAME
        {
          name: name,
          content: qwen_param_value(params, "path"),
          path: nil,
          scope: nil,
          start_line: qwen_param_value(params, "start_line"),
          end_line: qwen_param_value(params, "end_line")
        }
      when Tools::Write::NAME
        content = qwen_param_value(params, "content", "text", strip: false)
        { name: name, content: content, path: qwen_param_value(params, "path"), scope: nil }
      when Tools::MemoryRead::NAME
        memory_name = qwen_param_value(params, "name")
        { name: name, content: memory_name, path: nil, scope: qwen_param_value(params, "scope") }
      when Tools::MemoryWrite::NAME
        entry_name = qwen_param_value(params, "name")
        content = qwen_param_value(params, "content", "text", "body", "value", strip: false)
        { name: name, content: content, path: entry_name, scope: qwen_param_value(params, "scope"), description: qwen_param_value(params, "description") }
      when Tools::Edit::NAME
        old_text = qwen_param_value(params, "old_text", "old", strip: false)
        new_text = qwen_param_value(params, "new_text", "new", strip: false)
        content  = "<old>#{old_text}</old><new>#{new_text}</new>"
        {
          name: name,
          content: content,
          path: qwen_param_value(params, "path"),
          scope: nil,
          start_line: qwen_param_value(params, "start_line"),
          end_line: qwen_param_value(params, "end_line")
        }
      when Tools::TaskCreate::NAME
        {
          name: name,
          content: qwen_param_value(params, "command"),
          path: nil,
          scope: nil,
          cwd: qwen_param_value(params, "cwd"),
          env: qwen_param_value(params, "env", strip: false)
        }
      when Tools::TaskGet::NAME, Tools::TaskStop::NAME
        {
          name: name,
          content: qwen_param_value(params, "id", "task_id"),
          path: nil,
          scope: nil
        }
      when Tools::TaskWait::NAME
        {
          name: name,
          content: qwen_param_value(params, "id", "task_id"),
          path: nil,
          scope: nil,
          timeout: qwen_param_value(params, "timeout"),
          tail_lines: qwen_param_value(params, "tail_lines"),
          done_pattern: qwen_param_value(params, "done_pattern")
        }
      when Tools::TaskList::NAME
        { name: name, content: "", path: nil, scope: nil }
      when Tools::WebFetch::NAME
        { name: name, content: qwen_param_value(params, "url"), path: nil, scope: nil }
      when Tools::RegisterReminder::NAME
        {
          name: name,
          content: qwen_param_value(params, "name"),
          path: nil,
          scope: nil,
          description: qwen_param_value(params, "description"),
          interval_minutes: qwen_param_value(params, "interval_minutes")
        }
      when Tools::CancelReminder::NAME
        { name: name, content: qwen_param_value(params, "name"), path: nil, scope: nil }
      when Tools::ListReminders::NAME
        { name: name, content: "", path: nil, scope: nil }
      else
        { name: name, content: params.to_s, path: nil, scope: nil }
      end
    end

    def qwen_param_value(params, *keys, strip: true)
      value = keys.lazy.map { |key| params[key] }.find { |candidate| !candidate.nil? }
      return "" if value.nil?

      strip ? value.to_s.strip : value.to_s
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

    # Scan forward from +start+ for the next <| sequence that is NOT the Gemma
    # string delimiter <|"|>.  Returns the position of that <| or nil if none.
    def next_real_control_token(text, start)
      pos = start
      while (p = text.index(CONTROL_TOKEN_START, pos))
        # Skip over a <|"|> token entirely
        if text[p, GEMMA_STRING_DELIM.length] == GEMMA_STRING_DELIM
          pos = p + GEMMA_STRING_DELIM.length
        else
          return p
        end
      end
      nil
    end

    # Strip all occurrences of the Gemma string-delimiter token from +str+.
    # Used to clean up bare values that use <|"|> as quoting.
    def strip_gemma_delimiters(str)
      str.gsub(GEMMA_STRING_DELIM, "")
    end

    # Map native {key: "value"} params to the internal call hash.
    # Uses well-known named params for each tool; falls back to params_raw if
    # no recognised param is present.
    #
    # The model sometimes omits quotes and/or the space after the colon, e.g.
    #   {command:ruby -e 'puts 1'}  instead of  {command: "ruby -e 'puts 1'"}
    # In that case extract_native_params finds nothing and params_raw still
    # contains the "key:" prefix. strip_param_prefix removes it so the actual
    # command/path value is passed to the tool rather than the raw fragment.
    #
    # Gemma 4 may also use its <|"|> string delimiter token instead of plain
    # quotes. strip_gemma_delimiters is applied to all fallback values so that
    # <|"|>value<|"|> is cleaned to just "value" before being dispatched.
    def native_call(name, params_raw)
      params = extract_native_params(params_raw)

      case name
      when Tools::Execute::NAME
        content = params["command"] ||
                  strip_param_prefix(params_raw, "command") ||
                  params_raw
        { name: name, content: strip_gemma_delimiters(content), path: nil, scope: nil }
      when Tools::Read::NAME
        content = params["path"] ||
                  strip_param_prefix(params_raw, "path") ||
                  params_raw
        {
          name: name,
          content: strip_gemma_delimiters(content),
          path: nil,
          scope: nil,
          start_line: params["start_line"],
          end_line: params["end_line"]
        }
      when Tools::Write::NAME
        { name: name, content: params["content"] || "", path: params["path"], scope: nil }
      when Tools::MemoryRead::NAME
        content = params["name"] ||
                  strip_param_prefix(params_raw, "name") ||
                  params_raw
        { name: name, content: strip_gemma_delimiters(content), path: nil, scope: params["scope"] }
      when Tools::MemoryWrite::NAME
        # The declaration uses "name" (required) and "scope" (required).
        entry_name = params["name"] || ""
        { name: name, content: params["content"] || "", path: entry_name, scope: params["scope"], description: params["description"] ? strip_gemma_delimiters(params["description"]) : nil }
      when Tools::Edit::NAME
        old_text = params["old_text"] || params["old"] || ""
        new_text = params["new_text"] || params["new"] || ""
        content  = "<old>#{old_text}</old><new>#{new_text}</new>"
        {
          name: name,
          content: content,
          path: params["path"],
          scope: nil,
          start_line: params["start_line"],
          end_line: params["end_line"]
        }
      when Tools::TaskCreate::NAME
        command = params["command"] ||
                  strip_param_prefix(params_raw, "command") ||
                  params_raw
        {
          name: name,
          content: strip_gemma_delimiters(command),
          path: nil,
          scope: nil,
          cwd: params["cwd"],
          env: params["env"]
        }
      when Tools::TaskGet::NAME, Tools::TaskStop::NAME
        task_id = params["id"] ||
                  params["task_id"] ||
                  strip_param_prefix(params_raw, "id") ||
                  strip_param_prefix(params_raw, "task_id") ||
                  params_raw
        {
          name: name,
          content: strip_gemma_delimiters(task_id),
          path: nil,
          scope: nil
        }
      when Tools::TaskWait::NAME
        task_id = params["id"] ||
                  params["task_id"] ||
                  strip_param_prefix(params_raw, "id") ||
                  strip_param_prefix(params_raw, "task_id") ||
                  params_raw
        {
          name: name,
          content: strip_gemma_delimiters(task_id),
          path: nil,
          scope: nil,
          timeout: params["timeout"],
          tail_lines: params["tail_lines"],
          done_pattern: params["done_pattern"]
        }
      when Tools::TaskList::NAME
        { name: name, content: "", path: nil, scope: nil }
      when Tools::WebFetch::NAME
        content = params["url"] ||
                  strip_param_prefix(params_raw, "url") ||
                  params_raw
        { name: name, content: strip_gemma_delimiters(content), path: nil, scope: nil }
      when Tools::RegisterReminder::NAME
        content = params["name"] || strip_param_prefix(params_raw, "name") || params_raw
        {
          name: name,
          content: strip_gemma_delimiters(content),
          path: nil,
          scope: nil,
          description: params["description"] || "",
          interval_minutes: params["interval_minutes"] || "1"
        }
      when Tools::CancelReminder::NAME
        content = params["name"] || strip_param_prefix(params_raw, "name") || params_raw
        { name: name, content: strip_gemma_delimiters(content), path: nil, scope: nil }
      when Tools::ListReminders::NAME
        { name: name, content: "", path: nil, scope: nil }
      else
        # For future/unknown tools, pass along whatever the model provided
        { name: name, content: strip_gemma_delimiters(params_raw), path: nil, scope: nil }
      end
    end

    # Strip a known "key:" or "key: " prefix from a raw params string.
    # Returns the remainder of the string, or nil if the prefix is absent.
    # Handles both {command:value} (no space) and {command: value} (space).
    def strip_param_prefix(params_raw, key)
      return nil unless params_raw.start_with?("#{key}:")

      params_raw.sub(/\A#{Regexp.escape(key)}:\s*/, "")
    end

    # Extract key: "value" / key: 'value' / key:<|"|>value<|"|> pairs from a
    # native params string.
    # Atomic groups (?>…) prevent ReDoS on adversarial inputs.
    # Both quote styles and the Gemma 4 delimiter are always scanned;
    # double-quoted values take precedence.
    def extract_native_params(params_raw)
      params = {}
      params_raw.scan(/(\w+):\s*"((?>[^"\\]|\\.)*)"/) do |k, v|
        params[k] = unescape_native_value(v)
      end
      params_raw.scan(/(\w+):\s*'((?>[^'\\]|\\.)*)'/) do |k, v|
        params[k] ||= unescape_native_value(v)
      end
      params_raw.scan(/(\w+):\s*(-?\d+)/) do |k, v|
        params[k] ||= v
      end
      # Gemma 4 string delimiter: key:<|"|>value<|"|>
      # Use plain String#index to avoid any regex backtracking risk on the
      # value content (mirrors the approach used for control-token scanning).
      search_pos = 0
      while (delim_pos = params_raw.index(GEMMA_STRING_DELIM, search_pos))
        val_start = delim_pos + GEMMA_STRING_DELIM.length
        close_pos = params_raw.index(GEMMA_STRING_DELIM, val_start)
        break unless close_pos

        # Extract the key name by scanning backwards: strip trailing whitespace,
        # expect a colon, then extract trailing word characters — all without
        # a backtracking regex so there is no polynomial-ReDoS risk.
        prefix = params_raw[0...delim_pos].rstrip
        unless prefix.end_with?(":")
          search_pos = close_pos + GEMMA_STRING_DELIM.length
          next
        end

        key_part = prefix[0...-1].rstrip
        k_end    = key_part.length
        k_start  = k_end
        # Check each character directly (no regex) — no backtracking risk.
        while k_start > 0
          c = key_part[k_start - 1]
          break unless (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") ||
                       (c >= "0" && c <= "9") || c == "_"

          k_start -= 1
        end
        if k_start < k_end
          k = key_part[k_start...k_end]
          params[k] ||= params_raw[val_start...close_pos]
        end
        search_pos = close_pos + GEMMA_STRING_DELIM.length
      end
      params
    end

    def unescape_native_value(s)
      s.gsub('\\"', '"').gsub("\\'", "'").gsub("\\n", "\n").gsub("\\\\", "\\")
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
                 tool.call(call[:content], scope: call[:scope])
               when Tools::MemoryWrite::NAME
                 tool.call(call[:content], path: call[:path], scope: call[:scope], description: call[:description])
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
