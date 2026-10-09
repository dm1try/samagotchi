# frozen_string_literal: true

require "json"
require "monitor"
require "time"
require "fileutils"
require "securerandom"
require_relative "atomic_file"
require_relative "token_usage"
require_relative "model_price"
require_relative "session"

module Samagotchi
  # SessionMetrics is a persistent, error-isolated collector of per-session
  # analytics. It implements the same #call(event) sink contract as
  # SessionObserver subscribers, so Engine#run_turn feeds it (it forwards every
  # event to its SessionObserver): the REPL, the -p/--non-interactive/--resume
  # paths and SessionManager background workers.
  #
  # Each finished turn leaves a record (status, timings, model, prompt and
  # completion tokens, tool calls, iterations, retries, cuts); session totals are
  # sums over the records, kept as running counters as records are added, so
  # a worker that stops and wakes again (a new collector) keeps counting:
  # #session_id= loads the records already saved.
  # Prompt and completion counts come from every backend. Cached and reasoning
  # tokens, cost (OpenRouter's usage.cost) and the server's speeds (llama.cpp's
  # timings) are kept when the server reports them; a generation without a
  # server speed gets an estimated decode speed (see #close_generation).
  #
  # A snapshot is surfaced via Engine#session_state_snapshot (the Bridge's
  # /state, /snapshot, /stats and SSE frames) and persisted to a sibling
  # analytics.json next to the session file. The live snapshot carries the
  # totals and only the recent records (the newest finished turn's, plus any
  # not yet saved, at most LIVE_RECORDS_CAP turns), so it stays the same size
  # however long the session runs; analytics.json holds every record. The
  # event trail itself goes to the debug log (LogSubscriber).
  class SessionMetrics
    # The most turns (with their tool calls) a live snapshot carries: the
    # unsaved ones of a collector whose saves keep failing stay bounded.
    LIVE_RECORDS_CAP = 20
    # The most characters of a failed turn's error message its record keeps.
    FAILURE_MESSAGE_CHARS = 2000

    # A generation shorter than this gets no decode speed of its own: one
    # tiny generation would skew the session's average.
    SPEED_MIN_TOKENS = 8
    SPEED_MIN_MS = 100

    # The session's token totals as a saved analytics.json has them (zeros
    # where an older file lacks a count), with how full the context was.
    # A generation's decode speed (tokens per second) and where it came
    # from: "server" (llama.cpp's timings) or "estimate".
    GenerationSpeed = Data.define(:decode_tps, :source)

    # What #finish_generation reports: the generation's speed (nil when it
    # had none) and the session's tokens block as the snapshot has it.
    GenerationReport = Data.define(:speed, :tokens)

    # memory_index: the memory indexes the session's prompt held
    # ({ system: { tokens:, lines: }, project: … }, string keys as saved),
    # nil when an older file has none.
    # cost_estimate_sum: the estimated cost (hosts.<name>.models prices), 0
    # in an older file.
    SavedSummary = Data.define(:ctx_pct, :prompt_sum, :completion_sum, :cached_sum, :reasoning_sum, :cost_sum,
                               :cost_estimate_sum, :memory_index) do
      def initialize(memory_index: nil, cost_estimate_sum: 0, **) = super

      def tokens = to_h.except(:ctx_pct, :memory_index)
    end

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
      # The rest of this generation's server report: the largest cached and
      # reasoning counts (and cache writes), the last cost, and the server's speeds and decode
      # time (llama.cpp's timings); and when its first content, reasoning or
      # tool call chunk came (an estimated speed runs from there).
      :gen_cached_max,
      :gen_cache_write_max,
      :gen_reasoning_max,
      :gen_cost,
      # The generation's configured price (ModelPrice, from
      # :generation_started), what a generation without a reported cost
      # (or a reported 0) is estimated from.
      :gen_price,
      :gen_decode_tps,
      :gen_prefill_tps,
      :gen_decode_ms,
      :gen_first_chunk_at,
      # The turn's generations, folded as each one ends: the count, the last
      # one's prompt and completion, the sums, and which kinds of counts
      # (server / estimate) they came from; prompt_max is the largest
      # prompt (an LLM context edit can make a later one smaller).
      :generations,
      :prompt_last,
      :prompt_max,
      :prompt_sum,
      :completion_last,
      :completion_sum,
      :token_sources,
      # Summed over the turn's generations: cached and reasoning tokens, the
      # cost (nil until one reports it), and the decode time and completion
      # tokens of the generations with a speed. The last speeds and where the
      # decode one came from (server / estimate).
      :cached_sum,
      :cache_write_sum,
      # What the server prefilled again of the previous request's prompt
      # (KernelLoop#reprefilled_tokens; an LLM context edit's cache break).
      :reprefill_sum,
      :reasoning_sum,
      :cost_sum,
      # The estimated cost of the generations priced from config (0 when none).
      :cost_estimate_sum,
      :decode_ms_sum,
      :decode_tokens_sum,
      :last_decode_tps,
      :last_prefill_tps,
      :tps_source,
      :retries,
      # Generations a plugin cut (stop_generation: loop-guard's thinking
      # watch), not a steer's cut; and ones that ended at the output cap
      # (finish_reason length). `retries` counts the network's only.
      :cuts,
      :capped,
      :model,
      # The turn the user started by answering the step-limit question with
      # Continue (:turn_started's +continue+); its record carries it.
      :continue,
      :id,
      :started_at,
      :started_monotonic,
      :tool_calls_by_id,
      keyword_init: true
    )

    # How full the context was after the session's last counted turn, from
    # its saved analytics.json: a percentage, or nil when the file, the count
    # or the window is missing (the session lists read it per row).
    # @param session_dir [String]
    # @param budget_tokens [Integer, Proc, nil] the session's LLM context
    #   budget; a positive one smaller than the window is what the fill is
    #   counted against (the live meter counts the same way,
    #   ContextStatus#counted_against). nil or 0: the window. A callable is
    #   resolved only when there is a context to count, so a caller can build
    #   a registry lazily.
    # @return [Float, nil]
    def self.saved_context_pct(session_dir, budget_tokens: nil)
      saved_summary(session_dir, budget_tokens: budget_tokens)&.ctx_pct
    end

    # The context's fill and the token totals from the session's saved
    # analytics.json, read once; nil without a readable file.
    # @param session_dir [String]
    # @param budget_tokens [Integer, Proc, nil] see .saved_context_pct
    # @return [SavedSummary, nil]
    def self.saved_summary(session_dir, budget_tokens: nil)
      data = JSON.parse(File.read(File.join(session_dir, "analytics.json")))
      return nil unless data.is_a?(Hash)

      tokens = data["tokens"].is_a?(Hash) ? data["tokens"] : {}
      count = ->(key) { tokens[key].is_a?(Numeric) ? tokens[key] : 0 }
      SavedSummary.new(ctx_pct: saved_pct(data["context"], budget_tokens), prompt_sum: count.call("prompt_sum"),
                       completion_sum: count.call("completion_sum"), cached_sum: count.call("cached_sum"),
                       reasoning_sum: count.call("reasoning_sum"), cost_sum: count.call("cost_sum"),
                       cost_estimate_sum: count.call("cost_estimate_sum"),
                       memory_index: data["memory_index"].is_a?(Hash) ? data["memory_index"] : nil)
    rescue JSON::ParserError, SystemCallError, TypeError
      nil
    end

    def self.saved_pct(context, budget_tokens)
      return nil unless context.is_a?(Hash)

      used = context["used_tokens"]
      window = context["window_tokens"]
      return nil unless used.is_a?(Numeric) && window.is_a?(Numeric) && window.positive?

      used * 100.0 / counted_against(budget_tokens, window)
    end

    # What the saved fill counts against: the window, or the budget when one
    # is set and smaller (ContextStatus#counted_against, the live meter's
    # rule). The budget is resolved here, not by the caller, so a caller
    # that builds one lazily doesn't build it for a row with no context.
    def self.counted_against(budget_tokens, window_tokens)
      budget = budget_tokens.respond_to?(:call) ? budget_tokens.call : budget_tokens
      budget.is_a?(Numeric) && budget.positive? ? [budget, window_tokens].min : window_tokens
    end
    private_class_method :counted_against
    private_class_method :saved_pct

    # One turn's tool records from the session's saved analytics.json, in
    # call order (iteration, then call_index), string-keyed as saved: what a
    # join replays the turn's tool rows' durations from. Empty without a turn
    # id (an older session's prompt), the file, or records.
    # @param session_dir [String]
    # @param turn_id [String, nil]
    # @return [Array<Hash>]
    def self.saved_tool_records(session_dir, turn_id)
      return [] if turn_id.to_s.empty?

      records = JSON.parse(File.read(File.join(session_dir, "analytics.json")))["tool_records"]
      Array(records).select { |r| r.is_a?(Hash) && r["turn_id"] == turn_id }
                    .sort_by { |r| [r["iteration"].to_i, r["call_index"].to_i] }
    rescue JSON::ParserError, SystemCallError, TypeError
      []
    end

    # One turn's saved record from the session's analytics.json, string-keyed
    # as saved: what a join replays the turn's failure (or cancel) line from.
    # nil without a turn id (an older session's prompt), the file, records,
    # or a record for the turn.
    # @param session_dir [String]
    # @param turn_id [String, nil]
    # @return [Hash, nil]
    def self.saved_turn_record(session_dir, turn_id)
      return nil if turn_id.to_s.empty?

      records = JSON.parse(File.read(File.join(session_dir, "analytics.json")))["turn_records"]
      Array(records).find { |r| r.is_a?(Hash) && r["id"] == turn_id }
    rescue JSON::ParserError, SystemCallError, TypeError
      nil
    end

    # "ctx 12%" for the session lists, "" when unknown.
    # @param pct [Float, nil]
    # @return [String]
    def self.context_label(pct)
      pct ? "ctx #{pct.round}%" : ""
    end

    def initialize(clock: nil, wall_clock: nil)
      @mutex = Monitor.new
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @wall_clock = wall_clock || -> { Time.now }
      @session_id = nil
      @state_dir = nil
      @memory_index = nil
      @started_at = nil
      @last_activity_at = nil
      @turn = nil
      @turn_records = []
      @tool_records = []
      # How many turn records the last successful save (or the load) holds,
      # and how many were loaded (a woken collector's live records start empty).
      @persisted_turns = 0
      @loaded_turns = 0
      reset_totals
    end

    # /model: the window and prompt profile a turn reported were the old
    # model's; /stats resolves the new one's until its first turn reports.
    def forget_model_reports!
      @mutex.synchronize do
        @context_window_tokens = @context_window_source = nil
        @profile = @profile_source = nil
      end
    end

    # The memory indexes the session's prompt holds (SystemPrompt#memory_index:
    # { system: { tokens:, lines: }, project: … }), set by the Engine when
    # it builds the prompt it sends; the snapshot and analytics.json carry it.
    # @param block [Hash, nil]
    def memory_index=(block)
      @mutex.synchronize { @memory_index = block if block }
    end

    # The sessions dir analytics.json is read from and saved to (nil: the
    # XDG default). Set it before #session_id=.
    attr_writer :state_dir

    # Set the session id the collector is aggregating for. Safe to call multiple
    # times; the first non-empty id wins so later turns don't clobber it. The
    # first one loads the records a earlier process saved for it, once
    # (#snapshot, on hot paths, never reads the disk).
    # @param id [String, nil]
    # @return [void]
    def session_id=(id)
      return if id.nil? || id.to_s.empty?

      @mutex.synchronize do
        next if @session_id

        @session_id = id.to_s
        load_persisted
      end
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
            @turn.gen_price = generation_price(event[:price])
            @turn.gen_open = true
          end
        end
      when :generation_completed, :generation_cancelled
        record_served_model(event)
        count_cut(event)
        count_reprefill(event)
        record_generation_completed
      when :generation_retrying
        # The retry streams from the start: its counts replace the ones so far.
        @mutex.synchronize do
          if @turn
            @turn.retries += 1
            reset_generation_tokens
          end
        end
      when :turn_completed
        end_turn(status: "completed")
      when :turn_canceled
        end_turn(status: "canceled", reason: event[:cancellation_reason], by: event[:cancelled_by])
      when :turn_failed
        end_turn(status: "failed", failure: failure_fields(event))
      end

      @mutex.synchronize { @last_activity_at = now.iso8601(3) }
    rescue StandardError
      nil
    end

    # The session totals are sums over the turn records (the ones loaded from
    # disk and this process's), with the running turn's calls, iterations and
    # finished generations counted at once, so /stats agrees mid-turn.
    # :turn_records / :tool_records are the recent ones only: the newest
    # finished turn's and any not yet saved (at most LIVE_RECORDS_CAP turns),
    # with the running turn's finished calls; the full history is the
    # session's analytics.json.
    # @return [Hash] the current summary snapshot
    def snapshot
      @mutex.synchronize { build_snapshot(:recent) }
    end

    # Close the open generation now, ahead of its :generation_completed
    # (which then finds it closed), and report its speed with the session's
    # running token totals: what the event carries to the UIs.
    # @return [GenerationReport]
    def finish_generation
      @mutex.synchronize do
        speed = close_generation if @turn&.gen_open
        GenerationReport.new(speed: speed, tokens: tokens_block(@totals, @turn))
      end
    end

    # The served model a generation last reported and the name asked for
    # then, without building a snapshot (Engine#served_model).
    # @return [Hash] :served_model, :served_model_for
    def served_report
      @mutex.synchronize { { served_model: @served_model, served_model_for: @served_model_for } }
    end

    # Persist the summary snapshot, with every record, to a sibling
    # analytics.json in the session directory. Atomic write; failures are
    # swallowed (analytics must never break the running session).
    # @param state_dir [String, nil]
    # @return [Boolean] true on success
    def persist(state_dir: nil)
      sid, data, turn_count = @mutex.synchronize do
        [@session_id, build_snapshot(:all).merge(active_turn: nil, active_tools: []), @turn_records.size]
      end
      return false if sid.nil? || sid.to_s.empty?

      # Omitting state_dir lets Session.session_dir fall back to the default
      # (XDG) location; passing an explicit nil would override it and break
      # File.join.
      FileUtils.mkdir_p(dir = session_dir(sid, state_dir || @state_dir))
      path = File.join(dir, "analytics.json")
      AtomicFile.write(path, JSON.pretty_generate(data) + "\n")
      @mutex.synchronize { @persisted_turns = [@persisted_turns, turn_count].max }
      true
    rescue StandardError
      false
    end

    private

    # Caller holds the mutex. +records+: :recent (the live snapshot) or :all
    # (analytics.json).
    def build_snapshot(records_mode)
      totals = @totals
      turn = @turn
      in_flight = turn ? turn.tool_calls_by_id.values : []
      {
        session_id: @session_id,
        turns: @turn_records.size + (turn ? 1 : 0),
        cancellations: totals[:cancellations],
        tokens: tokens_block(totals, turn),
        context: context_block(@turn_records),
        memory_index: @memory_index,
        profile: @profile,
        profile_source: @profile_source,
        served_model: @served_model,
        served_model_for: @served_model_for,
        tool_calls_total: @tool_records.size + in_flight.size,
        tool_calls_by_tool: tally_into(totals[:by_tool].dup, in_flight),
        tool_errors: totals[:tool_errors],
        iterations_total: totals[:iterations] + (turn&.iteration_count || 0),
        gen_latency_ms: (totals[:gen_ms] + (turn&.gen_latency_accum || 0)).round,
        retries: totals[:retries] + (turn&.retries || 0),
        cuts: totals[:cuts] + (turn&.cuts || 0),
        capped: totals[:capped] + (turn&.capped || 0),
        started_at: @started_at,
        last_activity_at: @last_activity_at,
        # From the session's first start (an earlier process's too), to now.
        session_duration_ms: ms_since(@started_at),
        **records_view(records_mode),
        active_turn: active_turn_snapshot,
        active_tools: active_tool_snapshots
      }
    end

    # The session's token totals, with the running turn's finished
    # generations; the last speeds are the newest a generation reported.
    # Caller holds the mutex.
    def tokens_block(totals, turn)
      add = ->(key) { totals[key] + (turn&.public_send(key) || 0) }
      decode_ms = add.call(:decode_ms_sum)
      decode_tokens = add.call(:decode_tokens_sum)
      speed_turn = turn&.last_decode_tps ? turn : nil
      {
        prompt_sum: add.call(:prompt_sum),
        completion_sum: add.call(:completion_sum),
        cached_sum: add.call(:cached_sum),
        cache_write_sum: add.call(:cache_write_sum),
        reprefill_sum: add.call(:reprefill_sum),
        reasoning_sum: add.call(:reasoning_sum),
        cost_sum: add.call(:cost_sum),
        cost_estimate_sum: add.call(:cost_estimate_sum),
        decode_ms_sum: decode_ms.round,
        decode_tokens_sum: decode_tokens,
        avg_decode_tps: decode_ms.positive? ? (decode_tokens * 1000.0 / decode_ms).round(1) : nil,
        last_decode_tps: speed_turn ? speed_turn.last_decode_tps : totals[:last_decode_tps],
        last_prefill_tps: turn&.last_prefill_tps || totals[:last_prefill_tps],
        tps_source: speed_turn ? speed_turn.tps_source : totals[:tps_source],
        source: combined_source(totals[:token_sources] + (turn&.token_sources || []))
      }
    end

    # The records a snapshot carries, copied. :all is every record; :recent
    # the newest turn this collector finished (live before its save lands)
    # and the unsaved ones (capped), and the tool records of those turns and
    # of the running one. Records are appended in turn order, so both come
    # from the tails. Caller holds the mutex.
    def records_view(mode)
      return { turn_records: @turn_records.map(&:dup), tool_records: @tool_records.map(&:dup) } if mode == :all

      unsaved = @turn_records.size - @persisted_turns
      count = unsaved.clamp(@turn_records.size > @loaded_turns ? 1 : 0, LIVE_RECORDS_CAP)
      turns = @turn_records.last(count)
      ids = turns.to_set { |record| record[:id] }
      ids << @turn.id if @turn
      tools = @tool_records.reverse_each.take_while { |tool| ids.include?(tool[:turn_id]) }.reverse
      { turn_records: turns.map(&:dup), tool_records: tools.map(&:dup) }
    end

    def begin_turn(event)
      @mutex.synchronize do
        unless @session_id || event[:session_id].to_s.empty?
          @session_id = event[:session_id].to_s
          load_persisted
        end
        @started_at ||= now.iso8601(3)
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
          gen_cached_max: 0,
          gen_cache_write_max: 0,
          gen_reasoning_max: 0,
          generations: 0,
          prompt_last: nil,
          prompt_max: nil,
          prompt_sum: 0,
          completion_last: 0,
          completion_sum: 0,
          token_sources: [],
          cached_sum: 0,
          cache_write_sum: 0,
          reprefill_sum: 0,
          reasoning_sum: 0,
          cost_sum: nil,
          cost_estimate_sum: 0,
          decode_ms_sum: 0,
          decode_tokens_sum: 0,
          retries: 0,
          cuts: 0,
          capped: 0,
          model: nil,
          continue: event[:continue] ? true : false,
          id: event[:turn_id] || SecureRandom.uuid,
          started_at: now.iso8601(3),
          started_monotonic: monotonic_time,
          tool_calls_by_id: {}
        )
      end
    end

    # A canceled turn's record keeps why (+reason+: "user", "ctrl_c", ...)
    # and who stopped it (+by+: a hook's bundle), a failed one what its line
    # says (+failure+, #failure_fields), so a reloaded web history can show
    # the cancel or failure line the live one did.
    def end_turn(status: "completed", reason: nil, by: nil, failure: nil)
      @mutex.synchronize do
        if @turn
          # A turn that failed mid-stream never saw its generation end:
          # what it got to still counts.
          close_generation if @turn.gen_open
          # A call still running when the turn ends never completes: its
          # record says so, as the count already has it. A cancel stopped it
          # ("stopped", as ToolActivity names a call the Stop cut); a
          # failure left it "canceled".
          cut = status == "canceled" ? "stopped" : "canceled"
          @turn.tool_calls_by_id.each_value { |active| finish_tool_record(active, cut) }
          @turn.tool_calls_by_id.clear
          finished_at = now
          record = {
            id: @turn.id,
            status: status,
            started_at: @turn.started_at,
            completed_at: finished_at.iso8601(3),
            duration_ms: elapsed_ms(@turn.started_monotonic)
          }
          record[:cancellation_reason] = reason.to_s unless reason.nil? || reason.to_s.empty?
          record[:cancelled_by] = by.to_s unless by.nil? || by.to_s.empty?
          record[:failure] = failure if failure
          # Every record says, so the report can tell a file with no Continue
          # from one written before the mark.
          record[:continue] = @turn.continue
          record.merge!(turn_token_fields(@turn))
          @turn_records << record
          count_turn(record)
        end
        @turn = nil
      end
    end

    # What turn_failed's line is made of (format.js failedTurnText): a
    # provider error's summary, else the message (capped: a server's error
    # page can be long) and class, and the steps that stayed (kept_steps).
    def failure_fields(event)
      summary = event[:summary].to_s
      return { summary: summary, kept_steps: event[:kept_steps] }.compact unless summary.empty?

      message = event[:message].to_s
      message = "#{message[0, FAILURE_MESSAGE_CHARS - 1]}…" if message.length > FAILURE_MESSAGE_CHARS
      { message: message.empty? ? nil : message, error_class: event[:error_class]&.to_s,
        kept_steps: event[:kept_steps] }.compact
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

    def count_cut(event)
      @mutex.synchronize do
        next unless @turn

        @turn.cuts += 1 if event[:stopped_by] && event[:stopped_by].to_s != "steer"
        @turn.capped += 1 if event[:finish_reason].to_s == "length"
      end
    end

    # A generation's re-prefilled tokens (its :generation_completed's), into the turn.
    def count_reprefill(event)
      tokens = event[:reprefill_tokens]
      return unless tokens.is_a?(Integer) && tokens >= TokenUsage::REPREFILL_MIN_TOKENS

      @mutex.synchronize { @turn.reprefill_sum += tokens if @turn }
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
    # @return [GenerationSpeed, nil] the generation's speed, if it had one
    def close_generation
      turn = @turn
      turn.gen_open = false
      speed = nil
      if turn.gen_had_server
        completion = turn.gen_completion_max
        turn.prompt_last = turn.gen_prompt_max
        turn.prompt_max = [turn.prompt_max.to_i, turn.gen_prompt_max].max
        turn.prompt_sum += turn.gen_prompt_max
        turn.token_sources |= ["server"]
        speed = close_server_report(turn, completion)
      else
        completion = turn.gen_estimate_sum
        turn.token_sources |= ["estimate"] if completion.positive?
      end
      turn.completion_last = completion
      turn.completion_sum += completion
      started = turn.gen_started_at
      return speed unless started

      elapsed_ms = (monotonic_time - started) * 1000.0
      turn.gen_latency_accum += elapsed_ms if elapsed_ms > 0
      turn.gen_started_at = nil
      speed
    end

    # The generation's cached/reasoning counts, cost and decode speed, into
    # the turn. The speed is the server's (llama.cpp's predicted_per_second
    # over its predicted_ms) or, without one, an estimate: the completion
    # over the time from the first streamed chunk to now (that leaves out
    # queueing and the prefill). An estimated chars/4 generation never gets
    # here: it has no speed. Caller holds the mutex.
    def close_server_report(turn, completion)
      turn.cached_sum += turn.gen_cached_max
      turn.cache_write_sum += turn.gen_cache_write_max
      turn.reasoning_sum += turn.gen_reasoning_max
      turn.cost_sum = turn.cost_sum.to_f + turn.gen_cost if turn.gen_cost
      # A reported cost wins; a reported 0 with a price is taken as no report
      # (a gateway that doesn't bill per call); the 0 stays in cost.
      if turn.gen_price && (turn.gen_cost.nil? || turn.gen_cost.zero?)
        turn.cost_estimate_sum += turn.gen_price.cost(prompt_tokens: turn.gen_prompt_max, cached_tokens: turn.gen_cached_max,
                                                      cache_write_tokens: turn.gen_cache_write_max, completion_tokens: completion)
      end
      turn.last_prefill_tps = turn.gen_prefill_tps.round(1) if turn.gen_prefill_tps
      speed = generation_speed(turn, completion)
      return unless speed

      tps, decode_ms, source = speed
      turn.decode_ms_sum += decode_ms
      turn.decode_tokens_sum += completion
      turn.last_decode_tps = tps.round(1)
      turn.tps_source = source
      GenerationSpeed.new(decode_tps: turn.last_decode_tps, source: source)
    end

    # [tokens per second, decode ms, "server" | "estimate"], or nil for a
    # generation too short (or without a first chunk) to time.
    def generation_speed(turn, completion)
      if turn.gen_decode_tps && turn.gen_decode_ms
        decode_ms = turn.gen_decode_ms
        tps = turn.gen_decode_tps
        source = "server"
      elsif turn.gen_first_chunk_at
        decode_ms = (monotonic_time - turn.gen_first_chunk_at) * 1000.0
        tps = decode_ms.positive? ? completion * 1000.0 / decode_ms : 0
        source = "estimate"
      end
      return nil unless decode_ms && completion >= SPEED_MIN_TOKENS && decode_ms >= SPEED_MIN_MS

      [tps, decode_ms, source]
    end

    # The open generation's counts start over (a new generation, or a retry
    # that streams from the start). Its price stays: generation_started sets
    # it, and a retry sends none. Caller holds the mutex.
    def reset_generation_tokens
      @turn.gen_completion_max = 0
      @turn.gen_prompt_max = 0
      @turn.gen_had_server = false
      @turn.gen_estimate_sum = 0
      @turn.gen_cached_max = 0
      @turn.gen_cache_write_max = 0
      @turn.gen_reasoning_max = 0
      @turn.gen_cost = nil
      @turn.gen_decode_tps = @turn.gen_prefill_tps = @turn.gen_decode_ms = nil
      @turn.gen_first_chunk_at = nil
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
        prompt_tokens_max: turn.prompt_max,
        prompt_tokens_sum: turn.prompt_sum,
        completion_tokens: turn.completion_sum,
        context_used_tokens: turn.prompt_last && (turn.prompt_last + turn.completion_last),
        token_source: sources.size > 1 ? "mixed" : sources.first,
        gen_ms: turn.gen_latency_accum.round,
        tool_calls: turn.tool_calls,
        tool_errors: turn.tool_errors,
        iterations: turn.iteration_count,
        retries: turn.retries,
        cuts: turn.cuts,
        capped: turn.capped
      }.merge(turn_usage_fields(turn))
    end

    # The rest of the server's report: cached and reasoning tokens, the cost,
    # and the speeds (decode_tps is the turn's last generation's, decode_ms
    # and decode_tokens what the session's average is weighted by).
    def turn_usage_fields(turn)
      fields = {
        cached_tokens_sum: turn.cached_sum,
        reasoning_tokens: turn.reasoning_sum,
        decode_ms: turn.decode_ms_sum.round,
        decode_tokens: turn.decode_tokens_sum,
        decode_tps: turn.last_decode_tps,
        prefill_tps: turn.last_prefill_tps,
        tps_source: turn.tps_source
      }
      fields[:cache_write_tokens_sum] = turn.cache_write_sum if turn.cache_write_sum.positive?
      fields[:reprefill_tokens_sum] = turn.reprefill_sum if turn.reprefill_sum.positive?
      fields.merge!(cost: turn.cost_sum, cost_source: "reported") if turn.cost_sum
      fields[:cost_estimate] = turn.cost_estimate_sum if turn.cost_estimate_sum.positive?
      fields
    end

    def record_tool_call_start(event)
      @mutex.synchronize do
        return unless @turn

        @turn.tool_calls += 1
        tool = event[:tool].to_s
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

        finish_tool_record(active, status.empty? ? "ok" : status, waited_ms: event[:waited_ms].to_i)
      end
    end

    # Caller holds the mutex.
    def finish_tool_record(active, status, waited_ms: 0)
      record = active.slice(
        :id, :turn_id, :iteration, :call_index, :tool, :started_at
      ).merge(
        status: status,
        completed_at: now.iso8601(3),
        # Less a guardrail approval wait (ToolRunner's waited_ms).
        duration_ms: [elapsed_ms(active[:started_monotonic]) - waited_ms, 0].max
      )
      @tool_records << record
      count_tool(record)
    end

    # Accumulate token counts from a streamed generation_chunk payload.
    # Server-first: prefer real timings/usage. Prompt and completion tokens
    # are tracked as a per-generation MAX (the server's counts are cumulative
    # per request) and folded into the turn when the generation ends. When a generation reports
    # no server tokens at all we fall back to the chars/4 estimate summed across
    # its chunks (mutually exclusive with server counting to avoid double
    # counting a final chunk that carries timings while earlier chunks do not).
    def accumulate_tokens(event)
      payload = event[:payload]
      payload = {} unless payload.is_a?(Hash)

      @mutex.synchronize { note_first_chunk(payload, event) }
      usage = TokenUsage.from_payload(payload)
      if usage
        @mutex.synchronize { note_server_usage(usage) if @turn }
      else
        @mutex.synchronize do
          chars = event_content_chars(payload, event)
          return unless chars && chars.positive?
          return if @turn && @turn.gen_had_server

          @turn.gen_estimate_sum += TokenUsage.estimate(payload_content(payload, event)) if @turn
        end
      end
    end

    # Caller holds the mutex.
    def note_server_usage(usage)
      turn = @turn
      turn.gen_prompt_max = [turn.gen_prompt_max, usage.prompt_tokens.to_i].max
      turn.gen_completion_max = [turn.gen_completion_max, usage.completion_tokens.to_i].max
      turn.gen_cached_max = [turn.gen_cached_max, usage.cached_tokens.to_i].max
      turn.gen_cache_write_max = [turn.gen_cache_write_max, usage.cache_write_tokens.to_i].max
      turn.gen_reasoning_max = [turn.gen_reasoning_max, usage.reasoning_tokens.to_i].max
      turn.gen_cost = usage.cost if usage.cost
      if usage.predicted_per_second && usage.predicted_ms
        turn.gen_decode_tps = usage.predicted_per_second
        turn.gen_decode_ms = usage.predicted_ms
      end
      turn.gen_prefill_tps = usage.prompt_per_second if usage.prompt_per_second
      turn.gen_had_server = true
    end

    # The first chunk with content, reasoning or a tool call starts the
    # generation's decode clock (an estimated speed runs from it). Caller
    # holds the mutex.
    def note_first_chunk(payload, event)
      return unless @turn && @turn.gen_open && @turn.gen_first_chunk_at.nil?
      return unless !event[:content].to_s.empty? || tool_call_delta?(payload)

      @turn.gen_first_chunk_at = monotonic_time
    end

    def tool_call_delta?(payload)
      choice = payload["choices"].is_a?(Array) ? payload["choices"].first : nil
      choice.is_a?(Hash) && choice["delta"].is_a?(Hash) && !Array(choice["delta"]["tool_calls"]).empty?
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

    # The :generation_started event's price (ModelPrice#to_h), nil for none.
    def generation_price(hash)
      hash.is_a?(Hash) ? ModelPrice.new(**hash.transform_keys(&:to_sym)) : nil
    rescue ArgumentError
      nil
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

    # Wall-clock ms from an ISO 8601 stamp to now (0 without one).
    def ms_since(timestamp)
      return 0 unless timestamp

      [((now - Time.iso8601(timestamp.to_s)) * 1000.0).round, 0].max
    rescue ArgumentError
      0
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

    def session_dir(sid, state_dir)
      # Omitting state_dir lets Session.session_dir fall back to the default
      # (XDG) location; passing an explicit nil would override it.
      state_dir ? Session.session_dir(sid, state_dir: state_dir) : Session.session_dir(sid)
    end

    # The records an earlier process saved for this session (a missing or
    # broken file, or an older shape: nothing, or zeros where keys are
    # missing). Caller holds the mutex.
    def load_persisted
      path = File.join(session_dir(@session_id, @state_dir), "analytics.json")
      return unless File.file?(path)

      prior = JSON.parse(File.read(path))
      return unless prior.is_a?(Hash)

      loaded_turns = loaded_records(prior["turn_records"])
      @turn_records = loaded_turns + @turn_records
      @tool_records = loaded_records(prior["tool_records"]) + @tool_records
      @persisted_turns = @loaded_turns = loaded_turns.size
      # Once per collector: recount in record order (the tally's key order
      # stays first-seen).
      reset_totals
      @turn_records.each { |record| count_turn(record) }
      @tool_records.each { |record| count_tool(record) }
      @started_at = earliest_timestamp(prior["started_at"], @started_at)
      @last_activity_at ||= prior["last_activity_at"]
      # The served model last reported, with the name asked for then (the
      # Engine shows it only while that name is still the one asked for).
      if @served_model.nil? && prior["served_model"]
        @served_model = prior["served_model"]
        @served_model_for = prior["served_model_for"]
      end
      # The indexes the prompt last held, until this process builds its own.
      @memory_index ||= symbolized(prior["memory_index"]) if prior["memory_index"].is_a?(Hash)
      # The window last seen, until this process's first generation reports.
      window = prior["context"].is_a?(Hash) ? prior["context"] : {}
      if window["window_tokens"] && @context_window_tokens.nil?
        @context_window_tokens = window["window_tokens"]
        @context_window_source = window["window_source"]
      end
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def symbolized(hash)
      hash.to_h { |key, value| [key.to_sym, value.is_a?(Hash) ? symbolized(value) : value] }
    end

    def loaded_records(records)
      Array(records).filter_map { |record| record.transform_keys(&:to_sym) if record.is_a?(Hash) && record["id"] }
    end

    # The context as the newest turn with a count left it, and the window
    # now; readers compute the percentage.
    def context_block(records)
      last = records.reverse_each.find { |record| record[:context_used_tokens].is_a?(Numeric) }
      {
        used_tokens: last&.dig(:context_used_tokens),
        window_tokens: @context_window_tokens,
        window_source: @context_window_source&.to_s,
        source: last&.dig(:token_source),
        at: last&.dig(:completed_at)
      }
    end

    # The session totals over the finished records, as running counters
    # (#snapshot adds the running turn). Caller holds the mutex.
    def reset_totals
      @totals = { cancellations: 0, prompt_sum: 0, completion_sum: 0, token_sources: [], iterations: 0,
                  gen_ms: 0, retries: 0, cuts: 0, capped: 0, by_tool: {}, tool_errors: 0, cached_sum: 0, cache_write_sum: 0,
                  reprefill_sum: 0, reasoning_sum: 0,
                  cost_sum: 0, cost_estimate_sum: 0, decode_ms_sum: 0, decode_tokens_sum: 0, last_decode_tps: nil,
                  last_prefill_tps: nil, tps_source: nil }
    end

    def count_turn(record)
      totals = @totals
      totals[:cancellations] += 1 if record[:status] == "canceled"
      totals[:prompt_sum] += number(record[:prompt_tokens_sum])
      totals[:completion_sum] += number(record[:completion_tokens])
      totals[:iterations] += number(record[:iterations])
      totals[:gen_ms] += number(record[:gen_ms])
      totals[:retries] += number(record[:retries])
      totals[:cuts] += number(record[:cuts])
      totals[:capped] += number(record[:capped])
      totals[:cached_sum] += number(record[:cached_tokens_sum])
      totals[:cache_write_sum] += number(record[:cache_write_tokens_sum])
      totals[:reprefill_sum] += number(record[:reprefill_tokens_sum])
      totals[:reasoning_sum] += number(record[:reasoning_tokens])
      totals[:cost_sum] += number(record[:cost])
      totals[:cost_estimate_sum] += number(record[:cost_estimate])
      totals[:decode_ms_sum] += number(record[:decode_ms])
      totals[:decode_tokens_sum] += number(record[:decode_tokens])
      # The newest speeds a record has (an older record has none).
      if record[:decode_tps].is_a?(Numeric)
        totals[:last_decode_tps] = record[:decode_tps]
        totals[:tps_source] = record[:tps_source]
      end
      totals[:last_prefill_tps] = record[:prefill_tps] if record[:prefill_tps].is_a?(Numeric)
      source = record[:token_source]
      totals[:token_sources] |= [source.to_s] unless source.nil?
    end

    def count_tool(record)
      @totals[:tool_errors] += 1 if record[:status] == "error"
      tally_into(@totals[:by_tool], [record])
    end

    def tally_into(counts, tools)
      tools.each do |tool|
        name = tool[:tool].to_s
        counts[name] = counts.fetch(name, 0) + 1 unless name.empty?
      end
      counts
    end

    def number(value)
      value.is_a?(Numeric) ? value : 0
    end

    # server, estimate, or mixed when both kinds of counts (or a turn that
    # was already mixed) are in; nil before any.
    def combined_source(sources)
      kinds = sources.compact.map(&:to_s).flat_map { |source| source == "mixed" ? %w[server estimate] : [source] }.uniq
      kinds.size > 1 ? "mixed" : kinds.first
    end

    def earliest_timestamp(*timestamps)
      timestamps.compact.min_by { |value| Time.iso8601(value.to_s) }
    rescue ArgumentError
      timestamps.compact.first
    end
  end
end
