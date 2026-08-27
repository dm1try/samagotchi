# frozen_string_literal: true

require "json"
require "monitor"
require "time"
require "fileutils"
require_relative "session"

module Samagotchi
  # SessionMetrics is a persistent, error-isolated collector of per-session
  # analytics. It implements the same #call(event) sink contract as
  # SessionObserver subscribers, so it can be fed by both:
  #
  #   * Engine#run_turn (which forwards every event to its SessionObserver),
  #     covering the -p/--non-interactive/--resume paths and SessionManager
  #     background workers; and
  #   * TerminalUI's own stream handler, which forwards REPL events into the
  #     same instance because the interactive loop drives KernelLoop directly.
  #
  # Collected dimensions:
  #   - tokens (input/output/total), with a provenance flag (:server|:estimate)
  #   - turn count, tool calls (total / per-tool / error count)
  #   - iterations (tool-call rounds) per turn, aggregated
  #   - generation latency (monotonic clock across generation_* events)
  #   - cancellations and network retries
  #   - session wall-clock (first activity -> last activity)
  #
  # A snapshot is surfaced via Engine#session_state_snapshot and (optionally)
  # persisted to a sibling analytics.json next to the session file. Raw events
  # can be appended to a JSONL log for debugging only.
  class SessionMetrics
    # Per-turn transient state, reset on each turn_started.
    TurnState = Struct.new(
      :session_id,
      :iteration_count,
      :gen_started_at,
      :gen_latency_accum,
      :tool_calls,
      :tool_errors,
      # Per-generation completion-token tracking. A turn may contain several
      # generations (one per tool-call iteration); each generation's predicted_n
      # is cumulative within that generation and resets afterwards, so totals
      # must be summed per-generation (not taken as a global max).
      :gen_completion_max,
      :gen_had_server,
      # Buffered chars/4 estimate for the current generation; committed to the
      # turn total only if the generation ends with no server token data.
      :gen_estimate_sum,
      keyword_init: true
    )

    def initialize
      @mutex = Monitor.new
      @session_id = nil
      @turns = 0
      @tokens_in = 0
      @tokens_out = 0
      @tokens_total = 0
      @token_source = nil # :server | :estimate
      @tool_calls_total = 0
      @tool_calls_by_tool = Hash.new(0)
      @tool_errors = 0
      @iterations_total = 0
      @gen_latency_ms = 0
      @cancellations = 0
      @retries = 0
      @started_at = nil
      @last_activity_at = nil
      @turn = nil
    end

    # Set the session id the collector is aggregating for. Safe to call multiple
    # times; the first non-empty id wins so later turns don't clobber it.
    # @param id [String, nil]
    # @return [void]
    def session_id=(id)
      return if id.nil? || id.to_s.empty?

      @mutex.synchronize { @session_id ||= id.to_s }
    end

    # Event sink. Safe to call from any thread; errors are isolated by the
    # caller (SessionObserver / TerminalUI) but we still guard internally.
    # @param event [Hash]
    # @return [void]
    def call(event)
      return unless event.is_a?(Hash)

      type = event[:type]
      case type
      when :turn_started
        begin_turn(event)
      when :generation_chunk
        accumulate_tokens(event[:payload])
      when :tool_dispatch_started
        @turn&.iteration_count += 1
      when :tool_call_started
        record_tool_call_start(event)
      when :tool_call_completed
        record_tool_call_completed(event)
      when :generation_started
        if @turn
          @turn.gen_started_at = monotonic_time
          @turn.gen_completion_max = 0
          @turn.gen_had_server = false
          @turn.gen_estimate_sum = 0
        end
      when :generation_completed
        record_generation_completed
      when :generation_retrying
        @mutex.synchronize { @retries += 1 }
      when :turn_completed
        end_turn
      when :turn_canceled
        @mutex.synchronize { @cancellations += 1 }
        end_turn
      end

      @mutex.synchronize { @last_activity_at = Time.now.iso8601(3) }
    rescue StandardError
      nil
    end

    # @return [Hash] the current summary snapshot
    def snapshot
      @mutex.synchronize do
        {
          session_id: @session_id,
          turns: @turns,
          tokens_in: @tokens_in,
          tokens_out: @tokens_out,
          tokens_total: @tokens_total,
          token_source: @token_source,
          tool_calls_total: @tool_calls_total,
          tool_calls_by_tool: @tool_calls_by_tool.dup,
          tool_errors: @tool_errors,
          iterations_total: @iterations_total,
          gen_latency_ms: @gen_latency_ms,
          cancellations: @cancellations,
          retries: @retries,
          started_at: @started_at,
          last_activity_at: @last_activity_at
        }
      end
    end

    # Persist the summary snapshot to a sibling analytics.json in the session
    # directory. Atomic write; failures are swallowed (analytics must never
    # break the running session).
    # @param state_dir [String, nil]
    # @return [Boolean] true on success
    def persist(state_dir: nil)
      sid = @mutex.synchronize { @session_id }
      return false if sid.nil? || sid.to_s.empty?

      # Omitting state_dir lets Session.session_dir fall back to the default
      # (XDG) location; passing an explicit nil would override it and break
      # File.join.
      dir = state_dir ? Session.session_dir(sid, state_dir: state_dir) : Session.session_dir(sid)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "analytics.json")
      temp_path = "#{path}.tmp"
      File.write(temp_path, JSON.pretty_generate(snapshot) + "\n")
      File.rename(temp_path, path)
      true
    rescue StandardError
      false
    end

    private

    def begin_turn(event)
      @mutex.synchronize do
        @session_id ||= event[:session_id].to_s if event[:session_id]
        @started_at ||= Time.now.iso8601(3)
        @turns += 1
        @turn = TurnState.new(
          session_id: @session_id,
          iteration_count: 0,
          gen_started_at: nil,
          gen_latency_accum: 0,
          tool_calls: 0,
          tool_errors: 0,
          gen_completion_max: 0,
          gen_had_server: false,
          gen_estimate_sum: 0
        )
      end
    end

    def end_turn
      @mutex.synchronize do
        @iterations_total += @turn.iteration_count if @turn
        @gen_latency_ms += @turn.gen_latency_accum if @turn
        @tool_calls_total += @turn.tool_calls if @turn
        @tool_errors += @turn.tool_errors if @turn
        @turn = nil
      end
    end

    def record_generation_completed
      return unless @turn

      # Finalize this generation's completion tokens. Server timings are
      # cumulative per generation; we sum the per-generation max into the turn
      # total. If the generation reported no server tokens we commit the buffered
      # chars/4 estimate instead. The two paths are mutually exclusive per
      # generation, so a final chunk carrying timings while earlier chunks did
      # not will not double count.
      @mutex.synchronize do
        if @turn.gen_had_server
          @tokens_out += @turn.gen_completion_max
        else
          @tokens_out += @turn.gen_estimate_sum
        end
        @tokens_total = @tokens_in + @tokens_out
      end

      started = @turn.gen_started_at
      return unless started

      elapsed_ms = (monotonic_time - started) * 1000.0
      @turn.gen_latency_accum += elapsed_ms if elapsed_ms > 0
      @turn.gen_started_at = nil
    end

    def record_tool_call_start(event)
      return unless @turn

      @turn.tool_calls += 1
      tool = event[:tool].to_s
      @tool_calls_by_tool[tool] += 1 unless tool.empty?
    end

    def record_tool_call_completed(event)
      return unless @turn

      status = event[:status].to_s
      @turn.tool_errors += 1 if status == "error"
    end

    # Accumulate token counts from a streamed generation_chunk payload.
    # Server-first: prefer real timings/usage. Input tokens keep a running MAX
    # (the prompt grows across tool-call iterations); completion tokens are
    # tracked as a per-generation MAX and summed at generation_completed so
    # multi-generation turns count every generation. When a generation reports
    # no server tokens at all we fall back to the chars/4 estimate summed across
    # its chunks (mutually exclusive with server counting to avoid double
    # counting a final chunk that carries timings while earlier chunks do not).
    def accumulate_tokens(payload)
      return unless payload.is_a?(Hash)

      usage = TokenUsage.from_payload(payload)
      if usage
        @mutex.synchronize do
          @token_source = :server
          @tokens_in = [@tokens_in, usage[:prompt_tokens].to_i].max
          if @turn
            @turn.gen_completion_max = [@turn.gen_completion_max, usage[:completion_tokens].to_i].max
            @turn.gen_had_server = true
          end
          @tokens_total = @tokens_in + @tokens_out
        end
      else
        chars = event_content_chars(payload)
        return unless chars && chars.positive?
        return if @turn && @turn.gen_had_server

        @mutex.synchronize do
          @token_source ||= :estimate
          @turn.gen_estimate_sum += TokenUsage.estimate(payload_content(payload)) if @turn
          @tokens_total = @tokens_in + @tokens_out
        end
      end
    end

    def event_content_chars(payload)
      len = payload_content(payload).length
      len.positive? ? len : nil
    end

    def payload_content(payload)
      content = payload["content"] || payload[:content]
      content.is_a?(String) ? content : ""
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
