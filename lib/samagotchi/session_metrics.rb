# frozen_string_literal: true

require "json"
require "monitor"
require "time"
require "fileutils"
require "securerandom"
require_relative "session"

module Samagotchi
  # SessionMetrics is a persistent, error-isolated collector of per-session
  # analytics. It implements the same #call(event) sink contract as
  # SessionObserver subscribers, so Engine#run_turn feeds it (it forwards every
  # event to its SessionObserver): the REPL, the -p/--non-interactive/--resume
  # paths and SessionManager background workers.
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
  # persisted to a sibling analytics.json next to the session file. The event
  # trail itself goes to the debug log (LogSubscriber).
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
      # This generation's prompt (the server's count; the largest seen, as it
      # comes cumulative per request) and whether it is still streaming.
      :gen_prompt_max,
      :gen_open,
      # The turn's generations, folded as each one ends: the count, the last
      # one's prompt and completion, the sums, and which kinds of counts
      # (server / estimate) they came from.
      :generations,
      :prompt_last,
      :prompt_sum,
      :completion_last,
      :completion_sum,
      :token_sources,
      :retries,
      :model,
      :id,
      :started_at,
      :started_monotonic,
      :tool_calls_by_id,
      keyword_init: true
    )

    def initialize(clock: nil, wall_clock: nil)
      @mutex = Monitor.new
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @wall_clock = wall_clock || -> { Time.now }
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
      @turn_records = []
      @tool_records = []
    end

    # /model: the window and prompt profile a turn reported were the old
    # model's; /stats resolves the new one's until its first turn reports.
    def forget_model_reports!
      @mutex.synchronize do
        @context_window_tokens = @context_window_source = nil
        @profile = @profile_source = nil
      end
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
        accumulate_tokens(event)
      when :tool_dispatch_started
        @mutex.synchronize { @turn&.iteration_count += 1 }
      when :tool_call_started
        record_tool_call_start(event)
      when :tool_call_completed
        record_tool_call_completed(event)
      when :generation_started
        @mutex.synchronize do
          if event[:context_window_tokens]
            @context_window_tokens = event[:context_window_tokens]
            @context_window_source = event[:context_window_source]
          end
          if event[:profile]
            @profile = event[:profile]
            @profile_source = event[:profile_source]
          end
          if @turn
            @turn.gen_started_at = monotonic_time
            @turn.generations += 1
            reset_generation_tokens
            @turn.gen_open = true
          end
        end
      when :generation_completed, :generation_cancelled
        record_served_model(event)
        record_generation_completed
      when :generation_retrying
        # The retry streams from the start: its counts replace the ones so far.
        @mutex.synchronize do
          @retries += 1
          if @turn
            @turn.retries += 1
            reset_generation_tokens
          end
        end
      when :turn_completed
        end_turn(status: "completed")
      when :turn_canceled
        @mutex.synchronize { @cancellations += 1 }
        end_turn(status: "canceled", reason: event[:cancellation_reason])
      when :turn_failed
        end_turn(status: "failed")
      end

      @mutex.synchronize { @last_activity_at = now.iso8601(3) }
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
          context_window_tokens: @context_window_tokens,
          context_window_source: @context_window_source,
          profile: @profile,
          profile_source: @profile_source,
          served_model: @served_model,
          served_model_for: @served_model_for,
          # The running turn's calls, iterations and finished generations
          # count at once (the per-tool counts do too), so /stats agrees
          # mid-turn; end_turn moves them into the totals.
          tool_calls_total: @tool_calls_total + (@turn&.tool_calls || 0),
          tool_calls_by_tool: @tool_calls_by_tool.dup,
          tool_errors: @tool_errors + (@turn&.tool_errors || 0),
          iterations_total: @iterations_total + (@turn&.iteration_count || 0),
          gen_latency_ms: @gen_latency_ms + (@turn&.gen_latency_accum || 0),
          cancellations: @cancellations,
          retries: @retries,
          started_at: @started_at,
          last_activity_at: @last_activity_at,
          session_duration_ms: elapsed_ms(@session_started_monotonic),
          turn_records: @turn_records.map(&:dup),
          tool_records: @tool_records.map(&:dup),
          active_turn: active_turn_snapshot,
          active_tools: active_tool_snapshots
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
      File.write(temp_path, JSON.pretty_generate(merged_persisted_snapshot(path)) + "\n")
      File.rename(temp_path, path)
      true
    rescue StandardError
      false
    end

    private

    def begin_turn(event)
      @mutex.synchronize do
        @session_id ||= event[:session_id].to_s if event[:session_id]
        @started_at ||= now.iso8601(3)
        @session_started_monotonic ||= monotonic_time
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
          gen_estimate_sum: 0,
          gen_prompt_max: 0,
          gen_open: false,
          generations: 0,
          prompt_last: nil,
          prompt_sum: 0,
          completion_last: 0,
          completion_sum: 0,
          token_sources: [],
          retries: 0,
          model: nil,
          id: SecureRandom.uuid,
          started_at: now.iso8601(3),
          started_monotonic: monotonic_time,
          tool_calls_by_id: {}
        )
      end
    end

    # A canceled turn's record keeps why (+reason+: "user", "ctrl_c", ...), so
    # a reloaded web history can show the cancel line the live one did.
    def end_turn(status: "completed", reason: nil)
      @mutex.synchronize do
        if @turn
          # A turn that failed mid-stream never saw its generation end:
          # what it got to still counts.
          close_generation if @turn.gen_open
          finished_at = now
          record = {
            id: @turn.id,
            status: status,
            started_at: @turn.started_at,
            completed_at: finished_at.iso8601(3),
            duration_ms: elapsed_ms(@turn.started_monotonic)
          }
          record[:cancellation_reason] = reason.to_s unless reason.nil? || reason.to_s.empty?
          record.merge!(turn_token_fields(@turn))
          @turn_records << record
        end
        @iterations_total += @turn.iteration_count if @turn
        @gen_latency_ms += @turn.gen_latency_accum if @turn
        @tool_calls_total += @turn.tool_calls if @turn
        @tool_errors += @turn.tool_errors if @turn
        @turn = nil
      end
    end

    # The model the server says answered, and the name asked for then (a
    # /model switch makes it stale until the next generation reports).
    def record_served_model(event)
      return unless event[:served_model]

      @mutex.synchronize do
        @served_model = event[:served_model]
        @served_model_for = event[:requested_model]
        @turn.model = event[:served_model] if @turn
      end
    end

    def record_generation_completed
      @mutex.synchronize { close_generation if @turn&.gen_open }
    end

    # Finalize the open generation's tokens into the turn. Server counts are
    # cumulative per generation, so its max is its count. If the generation
    # reported no server tokens we commit the buffered chars/4 estimate
    # instead (there is no prompt count then). The two paths are mutually
    # exclusive per generation, so a final chunk carrying timings while
    # earlier chunks did not will not double count. Caller holds the mutex.
    def close_generation
      turn = @turn
      turn.gen_open = false
      if turn.gen_had_server
        completion = turn.gen_completion_max
        turn.prompt_last = turn.gen_prompt_max
        turn.prompt_sum += turn.gen_prompt_max
        turn.token_sources |= ["server"]
      else
        completion = turn.gen_estimate_sum
        turn.token_sources |= ["estimate"] if completion.positive?
      end
      turn.completion_last = completion
      turn.completion_sum += completion
      @tokens_out += completion
      @tokens_total = @tokens_in + @tokens_out
      started = turn.gen_started_at
      return unless started

      elapsed_ms = (monotonic_time - started) * 1000.0
      turn.gen_latency_accum += elapsed_ms if elapsed_ms > 0
      turn.gen_started_at = nil
    end

    # Caller holds the mutex.
    def reset_generation_tokens
      @turn.gen_completion_max = 0
      @turn.gen_prompt_max = 0
      @turn.gen_had_server = false
      @turn.gen_estimate_sum = 0
    end

    # The turn record's model and token fields. The context used at the end
    # is the last prompt plus the last answer (an estimated last generation
    # has no prompt count, so the turn's last known prompt stands in).
    def turn_token_fields(turn)
      sources = turn.token_sources
      {
        model: turn.model,
        generations: turn.generations,
        prompt_tokens: turn.prompt_last,
        prompt_tokens_sum: turn.prompt_sum,
        completion_tokens: turn.completion_sum,
        context_used_tokens: turn.prompt_last && (turn.prompt_last + turn.completion_last),
        token_source: sources.size > 1 ? "mixed" : sources.first,
        gen_ms: turn.gen_latency_accum.round,
        tool_calls: turn.tool_calls,
        tool_errors: turn.tool_errors,
        iterations: turn.iteration_count,
        retries: turn.retries
      }
    end

    def record_tool_call_start(event)
      @mutex.synchronize do
        return unless @turn

        @turn.tool_calls += 1
        tool = event[:tool].to_s
        @tool_calls_by_tool[tool] += 1 unless tool.empty?
        iteration = event[:iteration].to_i
        call_index = event[:call_index].to_i
        key = tool_key(iteration, call_index)
        @turn.tool_calls_by_id[key] = {
          id: "#{@turn.id}:#{key}",
          turn_id: @turn.id,
          iteration: iteration,
          call_index: call_index,
          tool: tool,
          started_at: now.iso8601(3),
          started_monotonic: monotonic_time
        }
      end
    end

    def record_tool_call_completed(event)
      @mutex.synchronize do
        return unless @turn

        status = event.dig(:activity, :status).to_s
        status = event[:status].to_s if status.empty?
        @turn.tool_errors += 1 if status == "error"
        key = tool_key(event[:iteration].to_i, event[:call_index].to_i)
        active = @turn.tool_calls_by_id.delete(key)
        return unless active

        finished_at = now
        @tool_records << active.slice(
          :id, :turn_id, :iteration, :call_index, :tool, :started_at
        ).merge(
          status: status.empty? ? "ok" : status,
          completed_at: finished_at.iso8601(3),
          duration_ms: elapsed_ms(active[:started_monotonic])
        )
      end
    end

    # Accumulate token counts from a streamed generation_chunk payload.
    # Server-first: prefer real timings/usage. Input tokens keep a running MAX
    # (the prompt grows across tool-call iterations); completion tokens are
    # tracked as a per-generation MAX and summed at generation_completed so
    # multi-generation turns count every generation. When a generation reports
    # no server tokens at all we fall back to the chars/4 estimate summed across
    # its chunks (mutually exclusive with server counting to avoid double
    # counting a final chunk that carries timings while earlier chunks do not).
    def accumulate_tokens(event)
      payload = event[:payload]
      payload = {} unless payload.is_a?(Hash)

      usage = TokenUsage.from_payload(payload)
      if usage
        @mutex.synchronize do
          @token_source = :server
          @tokens_in = [@tokens_in, usage[:prompt_tokens].to_i].max
          if @turn
            @turn.gen_prompt_max = [@turn.gen_prompt_max, usage[:prompt_tokens].to_i].max
            @turn.gen_completion_max = [@turn.gen_completion_max, usage[:completion_tokens].to_i].max
            @turn.gen_had_server = true
          end
          @tokens_total = @tokens_in + @tokens_out
        end
      else
        @mutex.synchronize do
          chars = event_content_chars(payload, event)
          return unless chars && chars.positive?
          return if @turn && @turn.gen_had_server

          @token_source ||= :estimate
          @turn.gen_estimate_sum += TokenUsage.estimate(payload_content(payload, event)) if @turn
          @tokens_total = @tokens_in + @tokens_out
        end
      end
    end

    def event_content_chars(payload, event)
      len = payload_content(payload, event).length
      len.positive? ? len : nil
    end

    def payload_content(payload, event = nil)
      content = payload["content"] || payload[:content]
      return content if content.is_a?(String)

      event_content = event && event[:content]
      event_content.is_a?(String) ? event_content : ""
    end

    def monotonic_time
      @clock.call
    end

    def now
      @wall_clock.call
    end

    def elapsed_ms(started)
      return 0 unless started

      [((monotonic_time - started) * 1000.0).round, 0].max
    end

    def tool_key(iteration, call_index)
      "#{iteration}:#{call_index}"
    end

    def active_turn_snapshot
      return nil unless @turn

      {
        id: @turn.id,
        started_at: @turn.started_at,
        duration_ms: elapsed_ms(@turn.started_monotonic)
      }
    end

    def active_tool_snapshots
      return [] unless @turn

      @turn.tool_calls_by_id.values.map do |tool|
        tool.slice(:id, :turn_id, :iteration, :call_index, :tool, :started_at).merge(
          duration_ms: elapsed_ms(tool[:started_monotonic])
        )
      end
    end

    def merged_persisted_snapshot(path)
      current = snapshot.merge(active_turn: nil, active_tools: [])
      return current unless File.file?(path)

      prior = JSON.parse(File.read(path))
      return current unless prior.is_a?(Hash)

      current.merge(
        started_at: earliest_timestamp(prior["started_at"], current[:started_at]),
        last_activity_at: latest_timestamp(prior["last_activity_at"], current[:last_activity_at]),
        turn_records: merge_records(prior["turn_records"], current[:turn_records]),
        tool_records: merge_records(prior["tool_records"], current[:tool_records])
      )
    rescue JSON::ParserError
      current
    end

    def merge_records(prior, current)
      (Array(prior) + Array(current)).each_with_object({}) do |record, by_id|
        next unless record.is_a?(Hash)

        id = record["id"] || record[:id]
        by_id[id] = record if id
      end.values
    end

    def earliest_timestamp(*timestamps)
      timestamps.compact.min_by { |value| Time.iso8601(value.to_s) }
    rescue ArgumentError
      timestamps.compact.first
    end

    def latest_timestamp(*timestamps)
      timestamps.compact.max_by { |value| Time.iso8601(value.to_s) }
    rescue ArgumentError
      timestamps.compact.last
    end
  end
end
