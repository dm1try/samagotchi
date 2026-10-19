# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_metrics"
require "samagotchi/token_usage"
require "samagotchi/side_usage"
require "samagotchi/llm/usage"

RSpec.describe Samagotchi::SessionMetrics do
  # A collector whose clocks never move: every timed field (gen_ms, decode_ms,
  # the durations, the stamp) stays put, so an example can't ride the machine's
  # speed. On the real monotonic clock two collectors rounded their gen_ms
  # apart (1 vs 0, CI run 39130480870). An example that asserts a duration
  # passes its own scripted clocks.
  def frozen_metrics(monotonic: 0.0, wall: Time.utc(2026, 9, 21, 10, 0, 0))
    described_class.new(clock: -> { monotonic }, wall_clock: -> { wall })
  end

  let(:metrics) { frozen_metrics }

  describe Samagotchi::SessionMetrics::Totals do
    it "merges counts, cancellations, token sources and the latest speeds" do
      record_counts = described_class::RECORD_SUMS.values.to_h { |key| [key, 1] }
      earlier = described_class.zero.add(record_counts.merge(status: "canceled", decode_tps: 11, tps_source: "estimate",
                                                             prefill_tps: 101, token_source: "estimate"))
      later = described_class.zero.add(record_counts.transform_values { 2 }.merge(status: "completed", decode_tps: 22,
                                                                                  tps_source: "server", prefill_tps: 202,
                                                                                  token_source: "server"))

      expected = described_class.zero.with(**described_class::RECORD_SUMS.keys.to_h { |key| [key, 3] },
                                           cancellations: 1, last_decode_tps: 22, tps_source: "server",
                                           last_prefill_tps: 202, token_sources: %w[estimate server].freeze)
      expect(earlier.merge(later)).to eq(expected)
    end
  end

  def feed(events)
    events.each { |e| metrics.call(e) }
  end

  it "names a turn's record by the engine's turn id (the one on the turn's prompt)" do
    feed([
      { type: :turn_started, session_id: "sess-1", prompt: "hi", turn_id: "turn-abc" },
      { type: :turn_failed }
    ])

    expect(metrics.snapshot[:turn_records].map { |r| r[:id] }).to eq(["turn-abc"])
  end

  it "marks a Continue turn's record with continue: true, and a normal one with continue: false" do
    feed([
      { type: :turn_started, session_id: "sess-1", prompt: "hi", turn_id: "turn-a" },
      { type: :turn_failed },
      { type: :turn_started, session_id: "sess-1", prompt: nil, turn_id: "turn-b", continue: true },
      { type: :turn_failed }
    ])

    records = metrics.snapshot[:turn_records]
    expect(records.map { |r| r[:id] }).to eq(%w[turn-a turn-b])
    expect(records.first).to include(continue: false)
    expect(records.last).to include(continue: true)
  end

  # A reminder's or a wake's turn is a continue too (no prompt of its own);
  # only a step-limit Continue resumes its run: resumed counts those.
  it "marks a step-limit Continue's record resumed: true, every other one resumed: false" do
    feed([
      { type: :turn_started, session_id: "sess-1", prompt: "hi", turn_id: "turn-a" },
      { type: :turn_completed },
      { type: :turn_started, session_id: "sess-1", prompt: nil, turn_id: "turn-r", continue: true },
      { type: :turn_completed },
      { type: :turn_started, session_id: "sess-1", prompt: nil, turn_id: "turn-k", continue: true, resumed: true },
      { type: :turn_completed }
    ])

    records = metrics.snapshot[:turn_records]
    expect(records.map { |r| r.slice(:continue, :resumed) }).to eq([{ continue: false, resumed: false },
                                                                    { continue: true, resumed: false },
                                                                    { continue: true, resumed: true }])
  end

  it "starts empty" do
    snap = metrics.snapshot
    expect(snap[:turns]).to eq(0)
    expect(snap[:tokens]).to include(prompt_sum: 0, completion_sum: 0, source: nil, cached_sum: 0, reasoning_sum: 0,
                                     cost_sum: 0, avg_decode_tps: nil, last_decode_tps: nil, tps_source: nil)
    expect(snap[:tool_calls_total]).to eq(0)
  end

  it "keeps the model the server last said it served, and the name asked for then" do
    feed([
      { type: :turn_started, session_id: "sess-1", prompt: "hi" },
      { type: :generation_started, iteration: 1 },
      { type: :generation_completed, iteration: 1, served_model: "ornith", requested_model: "qwen" },
      { type: :generation_started, iteration: 2 },
      { type: :generation_completed, iteration: 2 }
    ])

    expect(metrics.snapshot).to include(served_model: "ornith", served_model_for: "qwen")
    expect(metrics.served_report).to eq(served_model: "ornith", served_model_for: "qwen")
  end

  it "captures server-reported token counts (cumulative max) and tool stats" do
    feed([
      { type: :turn_started, session_id: "sess-1", prompt: "hi" },
      { type: :generation_started, iteration: 1 },
      { type: :generation_chunk, iteration: 1, content: "a", payload: { "timings" => { "prompt_n" => 120, "predicted_n" => 10 } } },
      { type: :generation_chunk, iteration: 1, content: "b", payload: { "timings" => { "prompt_n" => 120, "predicted_n" => 30 } } },
      { type: :tool_dispatch_started, iteration: 1, call_count: 2 },
      { type: :tool_call_started, iteration: 1, call_index: 1, tool: "read" },
      { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "read", status: "ok" },
      { type: :tool_call_started, iteration: 1, call_index: 2, tool: "execute" },
      { type: :tool_call_completed, iteration: 1, call_index: 2, tool: "execute", status: "error" },
      { type: :generation_completed, iteration: 1, content_length: 30 },
      { type: :turn_completed, result: double(respond_to?: false) }
    ])

    snap = metrics.snapshot
    expect(snap[:session_id]).to eq("sess-1")
    expect(snap[:turns]).to eq(1)
    expect(snap[:tokens]).to include(prompt_sum: 120, completion_sum: 30, source: "server")
    expect(snap[:tool_calls_total]).to eq(2)
    expect(snap[:tool_errors]).to eq(1)
    expect(snap[:tool_calls_by_tool]).to eq("read" => 1, "execute" => 1)
    expect(snap[:iterations_total]).to eq(1)
    expect(snap[:gen_latency_ms]).to be_a(Numeric)
    expect(snap[:cancellations]).to eq(0)
  end

  it "counts the running turn's tool calls and errors in the totals, once" do
    feed([
      { type: :turn_started, session_id: "sess-1", prompt: "hi" },
      { type: :generation_started, iteration: 1 },
      { type: :tool_call_started, iteration: 1, call_index: 1, tool: "read" },
      { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "read", status: "error" },
      { type: :tool_call_started, iteration: 1, call_index: 2, tool: "execute" }
    ])

    snap = metrics.snapshot
    expect(snap[:tool_calls_total]).to eq(2)
    expect(snap[:tool_errors]).to eq(1)
    expect(snap[:tool_calls_by_tool]).to eq("read" => 1, "execute" => 1)

    feed([
      { type: :tool_call_completed, iteration: 1, call_index: 2, tool: "execute", status: "ok" },
      { type: :generation_completed, iteration: 1, content_length: 3 },
      { type: :turn_completed, result: double(respond_to?: false) }
    ])
    expect(metrics.snapshot).to include(tool_calls_total: 2, tool_errors: 1)
  end

  it "marks a grep's no-match on its tool record, not as a tool error" do
    feed([
      { type: :turn_started, session_id: "sess-1", prompt: "hi" },
      { type: :tool_call_started, iteration: 1, call_index: 1, tool: "execute" },
      { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "execute",
        activity: { tool: "execute", status: "ok", no_match: true } },
      { type: :tool_call_started, iteration: 1, call_index: 2, tool: "execute" },
      { type: :tool_call_completed, iteration: 1, call_index: 2, tool: "execute",
        activity: { tool: "execute", status: "ok" } }
    ])
    snap = metrics.snapshot
    expect(snap[:tool_errors]).to eq(0)
    expect(snap[:tool_records].map { |record| record[:no_match] }).to eq([true, nil])
  end

  it "keeps a built-in run through call_tool on its record, never counted as an alias" do
    feed([
      { type: :turn_started, session_id: "sess-1", prompt: "hi" },
      { type: :tool_call_started, iteration: 1, call_index: 1, tool: "delegate" },
      { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "delegate", status: "ok",
        activity: { tool: "delegate", status: "ok", via: "call_tool" } },
      { type: :turn_completed, result: double(respond_to?: false) }
    ])
    snap = metrics.snapshot
    expect(snap[:tool_records].map { |record| record[:via] }).to eq(["call_tool"])
    expect(snap).not_to have_key(:tool_calls_aliased)
  end

  it "counts the calls a model made under an alias's name, by its spelling, only when there are any" do
    feed([
      { type: :turn_started, session_id: "sess-1", prompt: "hi" },
      { type: :generation_started, iteration: 1 },
      { type: :tool_call_started, iteration: 1, call_index: 1, tool: "execute" },
      { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "execute", status: "ok",
        activity: { tool: "execute", status: "ok" } }
    ])
    expect(metrics.snapshot).not_to have_key(:tool_calls_aliased)

    feed([
      { type: :tool_call_started, iteration: 1, call_index: 2, tool: "execute" },
      { type: :tool_call_completed, iteration: 1, call_index: 2, tool: "execute", status: "ok",
        activity: { tool: "execute", status: "ok", called_as: "bash" } },
      { type: :tool_call_started, iteration: 1, call_index: 3, tool: "execute" },
      { type: :tool_call_completed, iteration: 1, call_index: 3, tool: "execute", status: "ok",
        activity: { tool: "execute", status: "ok", called_as: "BASH" } },
      { type: :turn_completed, result: double(respond_to?: false) }
    ])

    snap = metrics.snapshot
    expect(snap[:tool_calls_by_tool]).to eq("execute" => 3)
    expect(snap[:tool_calls_aliased]).to eq("bash" => 1, "BASH" => 1)
    expect(snap[:tool_records].map { |record| record[:called_as] }).to eq([nil, "bash", "BASH"])
  end

  it "counts the running turn's iterations and generation latency in the totals, once" do
    monotonic = 10.0
    metrics = described_class.new(clock: -> { monotonic })
    [
      { type: :turn_started, session_id: "sess-1", prompt: "hi" },
      { type: :generation_started, iteration: 1 },
      { type: :tool_dispatch_started, iteration: 1 },
      { type: :tool_call_started, iteration: 1, call_index: 1, tool: "read" }
    ].each { |e| metrics.call(e) }
    monotonic = 10.5
    metrics.call({ type: :generation_completed, iteration: 1, content_length: 3 })

    expect(metrics.snapshot).to include(iterations_total: 1, gen_latency_ms: 500.0)

    metrics.call({ type: :turn_completed, result: double(respond_to?: false) })
    expect(metrics.snapshot).to include(iterations_total: 1, gen_latency_ms: 500.0)
  end

  it "keeps the latest context window :generation_started reported" do
    expect(metrics.snapshot[:context]).to include(window_tokens: nil, window_source: nil)

    feed([
      { type: :turn_started, session_id: "sess-1", prompt: "hi" },
      { type: :generation_started, iteration: 1, context_window_tokens: 256_000, context_window_source: :default },
      { type: :generation_started, iteration: 2, context_window_tokens: 128_000, context_window_source: :server },
      { type: :generation_started, iteration: 3 }
    ])

    expect(metrics.snapshot[:context]).to include(window_tokens: 128_000, window_source: "server")
  end

  describe "the context block" do
    def turn(prompt_tokens, completion_tokens, window: 1000)
      [
        { type: :turn_started, session_id: "ctx-sess", prompt: "p" },
        { type: :generation_started, iteration: 1, context_window_tokens: window, context_window_source: :server },
        { type: :generation_chunk, iteration: 1, content: "a",
          payload: { "usage" => { "prompt_tokens" => prompt_tokens, "completion_tokens" => completion_tokens } } },
        { type: :generation_completed, iteration: 1 },
        { type: :turn_completed }
      ]
    end

    it "is the newest turn's context used, with the window now" do
      feed(turn(100, 20) + turn(300, 50))

      context = metrics.snapshot[:context]
      expect(context).to include(used_tokens: 350, window_tokens: 1000, window_source: "server", source: "server")
      expect(context[:at]).to eq(metrics.snapshot[:turn_records].last[:completed_at])
    end

    it "keeps the last count when the newest turn has only an estimate" do
      feed(turn(300, 50) + [
        { type: :turn_started, session_id: "ctx-sess", prompt: "p" },
        { type: :generation_started, iteration: 1 },
        { type: :generation_chunk, iteration: 1, content: "abcd", payload: { "content" => "abcd" } },
        { type: :generation_cancelled, iteration: 1 },
        { type: :turn_canceled, cancellation_reason: :user }
      ])

      expect(metrics.snapshot[:context]).to include(used_tokens: 350, source: "server")
    end

    it "comes back, window too, in a new collector for the session" do
      state_dir = Dir.mktmpdir
      metrics.state_dir = state_dir
      feed(turn(300, 50, window: 4096))
      metrics.persist

      woken = frozen_metrics
      woken.state_dir = state_dir
      woken.session_id = "ctx-sess"

      expect(woken.snapshot[:context]).to include(used_tokens: 350, window_tokens: 4096, window_source: "server")
    end
  end

  describe "memory_index (the memory indexes the session's prompt holds)" do
    let(:index) { { system: { tokens: 1997, lines: 54 }, project: { tokens: 1394, lines: 35 } } }

    it "is nil until the Engine sets it, then in the snapshot; nil leaves the last one" do
      expect(metrics.snapshot[:memory_index]).to be_nil
      metrics.memory_index = index
      metrics.memory_index = nil
      expect(metrics.snapshot[:memory_index]).to eq(index)
    end

    it "is saved to analytics.json and comes back in a new collector until the prompt is built again" do
      state_dir = Dir.mktmpdir
      metrics.state_dir = state_dir
      metrics.session_id = "index-sess"
      metrics.memory_index = index
      metrics.persist
      expect(JSON.parse(File.read(File.join(state_dir, "index-sess", "analytics.json")))["memory_index"])
        .to eq("system" => { "tokens" => 1997, "lines" => 54 }, "project" => { "tokens" => 1394, "lines" => 35 })

      woken = frozen_metrics.tap { |m| m.state_dir = state_dir }
      woken.session_id = "index-sess"
      expect(woken.snapshot[:memory_index]).to eq(index)
      woken.memory_index = { system: { tokens: 1, lines: 1 } }
      expect(woken.snapshot[:memory_index]).to eq(system: { tokens: 1, lines: 1 })
    end
  end

  it "keeps the latest prompt profile :generation_started reported" do
    expect(metrics.snapshot).to include(profile: nil, profile_source: nil)

    feed([
      { type: :turn_started, session_id: "sess-1", prompt: "hi" },
      { type: :generation_started, iteration: 1, profile: "qwen36", profile_source: "server (chat_template)" },
      { type: :generation_started, iteration: 2 }
    ])

    expect(metrics.snapshot).to include(profile: "qwen36", profile_source: "server (chat_template)")
  end

  it "falls back to the chars/4 estimate when no server data is present" do
    feed([
      { type: :turn_started, session_id: "sess-2", prompt: "x" },
      { type: :generation_started, iteration: 1 },
      { type: :generation_chunk, iteration: 1, content: "hello world", payload: { "content" => "hello world" } },
      { type: :generation_completed, iteration: 1 },
      { type: :turn_completed, result: double(respond_to?: false) }
    ])

    snap = metrics.snapshot
    # 11 chars / 4.0 -> ceil -> 3; an estimate has no prompt count
    expect(snap[:tokens]).to include(prompt_sum: 0, completion_sum: 3, source: "estimate")
  end

  it "sums completion tokens across multiple generations in a tool-call loop" do
    feed([
      { type: :turn_started, session_id: "sess-multi", prompt: "x" },
      { type: :generation_started, iteration: 1 },
      { type: :generation_chunk, iteration: 1, payload: { "timings" => { "prompt_n" => 100, "predicted_n" => 10 } } },
      { type: :generation_completed, iteration: 1 },
      { type: :generation_started, iteration: 2 },
      { type: :generation_chunk, iteration: 2, payload: { "timings" => { "prompt_n" => 150, "predicted_n" => 25 } } },
      { type: :generation_completed, iteration: 2 },
      { type: :turn_completed, result: double(respond_to?: false) }
    ])

    snap = metrics.snapshot
    # Every request's prompt and answer, summed across generations.
    expect(snap[:tokens]).to include(prompt_sum: 250, completion_sum: 35, source: "server")
  end

  it "does not double count when timings arrive only on the final chunk" do
    feed([
      { type: :turn_started, session_id: "sess-final", prompt: "x" },
      { type: :generation_started, iteration: 1 },
      { type: :generation_chunk, iteration: 1, payload: { "content" => "hello world this is text" } },
      { type: :generation_chunk, iteration: 1, payload: { "timings" => { "prompt_n" => 50, "predicted_n" => 7 } } },
      { type: :generation_completed, iteration: 1 },
      { type: :turn_completed, result: double(respond_to?: false) }
    ])

    snap = metrics.snapshot
    # Server path wins: completion tokens = predicted_n (7), not 7 + estimate(27 chars).
    expect(snap[:tokens]).to include(completion_sum: 7, source: "server")
  end

  describe "the turn record's tokens" do
    def usage(prompt, completion) = { "usage" => { "prompt_tokens" => prompt, "completion_tokens" => completion } }

    it "folds each generation: last prompt, sums, context at the end, model and counts" do
      feed([
        { type: :turn_started, session_id: "sess-1", prompt: "hi" },
        { type: :generation_started, iteration: 1 },
        { type: :generation_chunk, iteration: 1, content: "a", payload: usage(100, 10) },
        { type: :tool_dispatch_started, iteration: 1, call_count: 1 },
        { type: :tool_call_started, iteration: 1, call_index: 1, tool: "read" },
        { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "read", status: "error" },
        { type: :generation_completed, iteration: 1, served_model: "ornith" },
        { type: :generation_started, iteration: 2 },
        { type: :generation_chunk, iteration: 2, content: "b", payload: usage(130, 20) },
        { type: :generation_completed, iteration: 2, served_model: "ornith" },
        { type: :turn_completed }
      ])

      expect(metrics.snapshot[:turn_records].last).to include(
        model: "ornith", generations: 2, prompt_tokens: 130, prompt_tokens_sum: 230, completion_tokens: 30,
        context_used_tokens: 150, token_source: "server", tool_calls: 1, tool_errors: 1, iterations: 1, retries: 0,
        cuts: 0, capped: 0
      )
      expect(metrics.snapshot[:turn_records].last[:gen_ms]).to be_a(Integer)
    end

    it "keeps the turn's largest prompt: an LLM context edit can make a later one smaller" do
      feed([
        { type: :turn_started, session_id: "sess-1", prompt: "hi" },
        { type: :generation_started, iteration: 1 },
        { type: :generation_chunk, iteration: 1, content: "a", payload: usage(500, 5) },
        { type: :generation_completed, iteration: 1 },
        { type: :generation_started, iteration: 2 },
        { type: :generation_chunk, iteration: 2, content: "b", payload: usage(300, 5) },
        { type: :generation_completed, iteration: 2 },
        { type: :turn_completed }
      ])

      expect(metrics.snapshot[:turn_records].last).to include(prompt_tokens: 300, prompt_tokens_max: 500)
    end

    it "keeps the prompt per generation, not the largest in the session" do
      feed([
        { type: :turn_started, session_id: "sess-1", prompt: "one" },
        { type: :generation_started, iteration: 1 },
        { type: :generation_chunk, iteration: 1, content: "a", payload: usage(900, 5) },
        { type: :generation_completed, iteration: 1 },
        { type: :turn_completed },
        # /compact or a new model: a smaller prompt afterwards.
        { type: :turn_started, session_id: "sess-1", prompt: "two" },
        { type: :generation_started, iteration: 1 },
        { type: :generation_chunk, iteration: 1, content: "b", payload: usage(200, 5) },
        { type: :generation_completed, iteration: 1 },
        { type: :turn_completed }
      ])

      expect(metrics.snapshot[:turn_records].last).to include(prompt_tokens: 200, context_used_tokens: 205)
    end

    it "marks a turn mixed when one generation has server counts and another only an estimate" do
      feed([
        { type: :turn_started, session_id: "sess-1", prompt: "hi" },
        { type: :generation_started, iteration: 1 },
        { type: :generation_chunk, iteration: 1, content: "a", payload: usage(100, 10) },
        { type: :generation_completed, iteration: 1 },
        { type: :generation_started, iteration: 2 },
        # A cancelled OpenAI stream: no usage chunk.
        { type: :generation_chunk, iteration: 2, content: "x" * 40, payload: { "content" => "x" * 40 } },
        { type: :generation_cancelled, iteration: 2 },
        { type: :turn_canceled, cancellation_reason: :user }
      ])

      expect(metrics.snapshot[:turn_records].last).to include(
        status: "canceled", generations: 2, prompt_tokens: 100, completion_tokens: 20, context_used_tokens: 110,
        token_source: "mixed"
      )
    end

    it "keeps the tokens of a generation still open when the turn fails" do
      feed([
        { type: :turn_started, session_id: "sess-1", prompt: "hi" },
        { type: :generation_started, iteration: 1 },
        { type: :generation_chunk, iteration: 1, content: "a", payload: usage(100, 7) },
        { type: :turn_failed, message: "stream broke" }
      ])

      expect(metrics.snapshot[:turn_records].last).to include(
        status: "failed", generations: 1, prompt_tokens: 100, completion_tokens: 7, token_source: "server"
      )
      expect(metrics.snapshot[:tokens][:completion_sum]).to eq(7)
    end

    it "counts a retried generation's estimate once" do
      feed([
        { type: :turn_started, session_id: "sess-1", prompt: "hi" },
        { type: :generation_started, iteration: 1 },
        { type: :generation_chunk, iteration: 1, content: "x" * 40, payload: { "content" => "x" * 40 } },
        { type: :generation_retrying, iteration: 1, attempt: 1 },
        { type: :generation_chunk, iteration: 1, content: "x" * 40, payload: { "content" => "x" * 40 } },
        { type: :generation_completed, iteration: 1 },
        { type: :turn_completed }
      ])

      expect(metrics.snapshot[:turn_records].last).to include(
        generations: 1, completion_tokens: 10, prompt_tokens: nil, context_used_tokens: nil,
        token_source: "estimate", retries: 1
      )
    end
  end

  describe "cached and reasoning tokens, cost and speed" do
    let(:monotonic) { [100.0] }
    let(:metrics) { described_class.new(clock: -> { monotonic[0] }) }

    def tick(seconds) = monotonic[0] += seconds

    def llama_chunk(content, completion, timings = nil)
      payload = { "usage" => { "prompt_tokens" => 300, "completion_tokens" => completion,
                               "prompt_tokens_details" => { "cached_tokens" => 280 } } }
      payload["timings"] = timings if timings
      { type: :generation_chunk, iteration: 1, content: content, payload: payload }
    end

    def router_chunk(content, completion, cost: nil, reasoning: nil)
      usage = { "prompt_tokens" => 1000, "completion_tokens" => completion }
      usage["cost"] = cost if cost
      usage["completion_tokens_details"] = { "reasoning_tokens" => reasoning } if reasoning
      { type: :generation_chunk, iteration: 1, content: content, payload: { "choices" => [], "usage" => usage } }
    end

    # A generation whose speed is timed by the clock: the first chunk after
    # +wait+ s (queueing and prefill), the last +decode+ s later.
    def estimated_generation(completion, wait: 0.5, decode: 1.0, cost: nil)
      metrics.call(type: :generation_started, iteration: 1)
      tick(wait)
      metrics.call(type: :generation_chunk, iteration: 1, content: "a", payload: { "choices" => [{ "delta" => {} }] })
      tick(decode)
      metrics.call(router_chunk("", completion, cost: cost))
      metrics.call(type: :generation_completed, iteration: 1)
    end

    def start_turn(id = "t1") = metrics.call(type: :turn_started, session_id: "speed", prompt: "p", turn_id: id)

    it "takes the server's exact speeds and cached count" do
      start_turn
      metrics.call(type: :generation_started, iteration: 1)
      metrics.call(llama_chunk("a", 10))
      metrics.call(llama_chunk("", 56, { "cache_n" => 280, "prompt_per_second" => 1900.04, "predicted_ms" => 640.0,
                                         "predicted_per_second" => 87.46 }))
      metrics.call(type: :generation_completed, iteration: 1)
      metrics.call(type: :turn_completed)

      expect(metrics.snapshot[:tokens]).to include(cached_sum: 280, last_decode_tps: 87.5, last_prefill_tps: 1900.0,
                                                   tps_source: "server", decode_ms_sum: 640, decode_tokens_sum: 56,
                                                   avg_decode_tps: 87.5, cost_sum: 0)
      expect(metrics.snapshot[:turn_records].last).to include(cached_tokens_sum: 280, decode_tps: 87.5, prefill_tps: 1900.0,
                                                              tps_source: "server", decode_ms: 640, decode_tokens: 56)
      expect(metrics.snapshot[:turn_records].last).not_to include(:cost)
    end

    it "sums the cache writes a server reports into the turn record and the totals, and keeps none it wasn't told of" do
      start_turn
      metrics.call(type: :generation_started, iteration: 1)
      write = router_chunk("a", 5)
      write[:payload]["usage"]["prompt_tokens_details"] = { "cached_tokens" => 0, "cache_write_tokens" => 14_728 }
      metrics.call(write)
      metrics.call(type: :generation_completed, iteration: 1)
      metrics.call(type: :turn_completed)

      expect(metrics.snapshot[:tokens]).to include(cache_write_sum: 14_728)
      expect(metrics.snapshot[:turn_records].last).to include(cache_write_tokens_sum: 14_728)

      start_turn("t2")
      metrics.call(type: :generation_started, iteration: 1)
      metrics.call(router_chunk("a", 5))
      metrics.call(type: :generation_completed, iteration: 1)
      metrics.call(type: :turn_completed)
      expect(metrics.snapshot[:turn_records].last).not_to include(:cache_write_tokens_sum)
      expect(metrics.snapshot[:tokens]).to include(cache_write_sum: 14_728)
    end

    it "sums the generations' re-prefilled tokens into the turn record and the session's tokens" do
      start_turn
      metrics.call(type: :generation_started, iteration: 1)
      metrics.call(router_chunk("a", 5))
      metrics.call(type: :generation_completed, iteration: 1, reprefill_tokens: 2_100)
      metrics.call(type: :generation_started, iteration: 2)
      metrics.call(router_chunk("a", 5))
      metrics.call(type: :generation_completed, iteration: 2, reprefill_tokens: 100)
      metrics.call(type: :turn_completed)

      expect(metrics.snapshot[:turn_records].last).to include(reprefill_tokens_sum: 2_100)
      start_turn("t2")
      metrics.call(type: :generation_started, iteration: 1)
      metrics.call(router_chunk("a", 5))
      metrics.call(type: :generation_completed, iteration: 1, reprefill_tokens: 900)
      expect(metrics.snapshot[:tokens]).to include(reprefill_sum: 3_000)
      metrics.call(type: :turn_completed)
      expect(metrics.snapshot[:tokens]).to include(reprefill_sum: 3_000)
    end

    it "estimates the decode speed from the first streamed chunk, not from the request, with cost and reasoning" do
      start_turn
      metrics.call(type: :generation_started, iteration: 1)
      tick(2.0)
      metrics.call(router_chunk("a", 1))
      tick(0.5)
      metrics.call(router_chunk("", 40, cost: 0.25, reasoning: 12))
      metrics.call(type: :generation_completed, iteration: 1)

      expect(metrics.snapshot[:tokens]).to include(last_decode_tps: 80.0, tps_source: "estimate", reasoning_sum: 12,
                                                   cost_sum: 0.25, last_prefill_tps: nil, cached_sum: 0)
      metrics.call(type: :turn_completed)
      expect(metrics.snapshot[:turn_records].last).to include(cost: 0.25, cost_source: "reported", reasoning_tokens: 12)
    end

    # The loop marks a tool call's chunk (tool_call: true) whatever the
    # wire's shape: ChatLoop asks its adapter, KernelLoop its native split.
    it "starts the clock on a tool call delta too" do
      start_turn
      metrics.call(type: :generation_started, iteration: 1)
      tick(1.0)
      metrics.call(type: :generation_chunk, iteration: 1, content: "", tool_call: true, payload: {})
      tick(0.25)
      metrics.call(router_chunk("", 20))
      metrics.call(type: :generation_completed, iteration: 1)

      expect(metrics.snapshot[:tokens]).to include(last_decode_tps: 80.0)
    end

    it "weights the session average by tokens, and gives tiny generations no speed of their own" do
      start_turn
      estimated_generation(100, decode: 1.0)
      estimated_generation(10, decode: 1.0)
      expect(metrics.snapshot[:tokens]).to include(last_decode_tps: 10.0, decode_tokens_sum: 110, avg_decode_tps: 55.0)

      estimated_generation(7, decode: 1.0)
      estimated_generation(50, decode: 0.05)
      expect(metrics.snapshot[:tokens]).to include(last_decode_tps: 10.0, decode_tokens_sum: 110, avg_decode_tps: 55.0)
    end

    it "gives a chars/4 estimated generation no speed and no cached count" do
      start_turn
      metrics.call(type: :generation_started, iteration: 1)
      metrics.call(type: :generation_chunk, iteration: 1, content: "x" * 400, payload: nil)
      tick(2.0)
      metrics.call(type: :generation_completed, iteration: 1)

      expect(metrics.snapshot[:tokens]).to include(completion_sum: 100, last_decode_tps: nil, cached_sum: 0,
                                                   decode_tokens_sum: 0)
    end

    it "times a retried generation from the retry's first chunk, and counts its report once" do
      start_turn
      metrics.call(type: :generation_started, iteration: 1)
      metrics.call(router_chunk("a", 5, cost: 0.5))
      tick(5.0)
      metrics.call(type: :generation_retrying, iteration: 1, attempt: 1)
      tick(1.0)
      metrics.call(router_chunk("b", 1))
      tick(0.5)
      metrics.call(router_chunk("", 30, cost: 0.25))
      metrics.call(type: :generation_completed, iteration: 1)

      expect(metrics.snapshot[:tokens]).to include(last_decode_tps: 60.0, cost_sum: 0.25, completion_sum: 30)
    end

    it "times a generation cut mid-stream by the estimate (a cut native stream has no timings)" do
      start_turn
      metrics.call(type: :generation_started, iteration: 1)
      metrics.call(type: :generation_chunk, iteration: 1, content: "a", payload: { "tokens_evaluated" => 300, "tokens_predicted" => 1 })
      tick(1.0)
      metrics.call(type: :generation_chunk, iteration: 1, content: "b", payload: { "tokens_evaluated" => 300, "tokens_predicted" => 30 })
      metrics.call(type: :generation_cancelled, iteration: 1)
      metrics.call(type: :turn_canceled, cancellation_reason: :user)

      expect(metrics.snapshot[:turn_records].last).to include(decode_tps: 30.0, tps_source: "estimate", decode_tokens: 30)
    end

    it "keeps the newest speed's source when a session mixes server and estimated speeds" do
      start_turn
      metrics.call(type: :generation_started, iteration: 1)
      metrics.call(llama_chunk("a", 50, { "predicted_per_second" => 50.0, "predicted_ms" => 1000.0 }))
      metrics.call(type: :generation_completed, iteration: 1)
      estimated_generation(150, decode: 1.0)
      metrics.call(type: :turn_completed)

      expect(metrics.snapshot[:tokens]).to include(last_decode_tps: 150.0, tps_source: "estimate", avg_decode_tps: 100.0)
    end

    it "finish_generation closes the generation once and reports its speed with the running totals" do
      start_turn
      metrics.call(type: :generation_started, iteration: 1)
      tick(1.0)
      metrics.call(router_chunk("a", 1))
      tick(0.5)
      metrics.call(router_chunk("", 40, cost: 0.25))

      report = metrics.finish_generation
      expect(report.speed).to eq(described_class::GenerationSpeed.new(decode_tps: 80.0, source: "estimate"))
      expect(report.tokens).to include(completion_sum: 40, cost_sum: 0.25, last_decode_tps: 80.0)
      metrics.call(type: :generation_completed, iteration: 1)
      expect(metrics.snapshot[:tokens]).to include(completion_sum: 40, cost_sum: 0.25)
      expect(metrics.finish_generation.speed).to be_nil
    end

    describe "the cost estimate from a configured price (hosts.<name>.models.<id>.price)" do
      let(:price) { { input: 2.0, cache_read: 0.5, cache_write: 2.0, output: 10.0 } }

      # router_chunk: 1000 prompt tokens, none cached, +completion+ out.
      def estimate_for(completion) = ((1000 * 2.0) + (completion * 10.0)) / 1e6

      def priced_generation(completion, cost: nil, price: self.price, chunk: true)
        metrics.call(type: :generation_started, iteration: 1, price: price)
        if chunk
          metrics.call(router_chunk("", completion, cost: cost))
        else
          metrics.call(type: :generation_chunk, iteration: 1, content: "x" * 40, payload: { "choices" => [] })
        end
        metrics.call(type: :generation_completed, iteration: 1)
      end

      it "doesn't estimate when the provider reports a cost" do
        start_turn
        priced_generation(40, cost: 0.25)
        metrics.call(type: :turn_completed)

        expect(metrics.snapshot[:tokens]).to include(cost_sum: 0.25, cost_estimate_sum: 0)
        expect(metrics.snapshot[:turn_records].last).to include(cost: 0.25, cost_source: "reported")
        expect(metrics.snapshot[:turn_records].last).not_to include(:cost_estimate)
      end

      it "estimates a generation the provider reports no cost for" do
        start_turn
        priced_generation(40)
        metrics.call(type: :turn_completed)

        expect(metrics.snapshot[:tokens][:cost_estimate_sum]).to be_within(1e-12).of(estimate_for(40))
        expect(metrics.snapshot[:tokens][:cost_sum]).to eq(0)
        expect(metrics.snapshot[:turn_records].last[:cost_estimate]).to be_within(1e-12).of(estimate_for(40))
        expect(metrics.snapshot[:turn_records].last).not_to include(:cost)
      end

      it "keeps the generation's price across a retry, which sends no new generation_started" do
        start_turn
        metrics.call(type: :generation_started, iteration: 1, price: price)
        metrics.call(type: :generation_retrying, iteration: 1, attempt: 1, restarted: true)
        metrics.call(router_chunk("", 40))
        metrics.call(type: :generation_completed, iteration: 1)
        metrics.call(type: :turn_completed)

        expect(metrics.snapshot[:tokens][:cost_estimate_sum]).to be_within(1e-12).of(estimate_for(40))
      end

      it "estimates a reported 0 when a price is configured, and keeps the reported 0 as the cost" do
        start_turn
        priced_generation(40, cost: 0)
        metrics.call(type: :turn_completed)

        expect(metrics.snapshot[:turn_records].last).to include(cost: 0.0, cost_source: "reported")
        expect(metrics.snapshot[:turn_records].last[:cost_estimate]).to be_within(1e-12).of(estimate_for(40))
      end

      it "leaves a reported 0 alone without a price" do
        start_turn
        priced_generation(40, cost: 0, price: nil)
        metrics.call(type: :turn_completed)

        expect(metrics.snapshot[:turn_records].last).to include(cost: 0.0)
        expect(metrics.snapshot[:turn_records].last).not_to include(:cost_estimate)
        expect(metrics.snapshot[:tokens]).to include(cost_estimate_sum: 0)
      end

      it "keeps a turn's reported and estimated generations apart" do
        start_turn
        priced_generation(40, cost: 0.25)
        priced_generation(10)
        metrics.call(type: :turn_completed)

        record = metrics.snapshot[:turn_records].last
        expect(record[:cost]).to eq(0.25)
        expect(record[:cost_estimate]).to be_within(1e-12).of(estimate_for(10))
      end

      it "doesn't estimate a generation with only chars/4 counts" do
        start_turn
        priced_generation(0, chunk: false)
        metrics.call(type: :turn_completed)

        expect(metrics.snapshot[:turn_records].last).not_to include(:cost_estimate)
        expect(metrics.snapshot[:tokens]).to include(cost_estimate_sum: 0)
      end

      it "shows the running turn's estimate and brings both sums back apart on reload" do
        dir = Dir.mktmpdir
        metrics.state_dir = dir
        start_turn("t1")
        priced_generation(40, cost: 0.25)
        priced_generation(10)
        expect(metrics.snapshot[:tokens][:cost_estimate_sum]).to be_within(1e-12).of(estimate_for(10))
        metrics.call(type: :turn_completed)
        start_turn("t2")
        priced_generation(20, cost: 0)
        metrics.call(type: :turn_completed)
        metrics.persist

        woken = frozen_metrics.tap { |m| m.state_dir = dir }
        woken.session_id = "speed"
        expect(woken.snapshot[:tokens][:cost_sum]).to eq(0.25)
        expect(woken.snapshot[:tokens][:cost_estimate_sum]).to be_within(1e-12).of(estimate_for(10) + estimate_for(20))
        summary = described_class.saved_summary(Samagotchi::Session.session_dir("speed", state_dir: dir))
        expect(summary.cost_sum).to eq(0.25)
        expect(summary.cost_estimate_sum).to be_within(1e-12).of(estimate_for(10) + estimate_for(20))
      end
    end

    describe "#cost (ctx.cost's value)" do
      let(:price) { { input: 2.0, cache_read: 0.5, cache_write: 2.0, output: 10.0 } }

      def estimate_for(completion) = ((1000 * 2.0) + (completion * 10.0)) / 1e6

      def priced_generation(completion, cost: nil, price: self.price)
        metrics.call(type: :generation_started, iteration: 1, price: price)
        metrics.call(router_chunk("", completion, cost: cost))
        metrics.call(type: :generation_completed, iteration: 1)
      end

      def side(cost: nil, price: nil)
        Samagotchi::SideUsage.new(kind: "btw", model: "m", prompt_tokens: 1000, completion_tokens: 20, cached_tokens: 0,
                                  cache_write_tokens: 0, reasoning_tokens: 0, cost: cost, price: price)
      end

      it "is zero and known before anything ran, and frozen" do
        cost = metrics.cost
        expect([cost.total, cost.reported, cost.estimated, cost.side, cost.known?]).to eq([0.0, 0.0, 0.0, 0.0, true])
        expect(cost).to be_frozen
      end

      it "counts the running turn's finished generations before turn_completed" do
        start_turn
        priced_generation(40, cost: 0.25)
        expect(metrics.cost).to have_attributes(reported: 0.25, estimated: 0.0, total: 0.25, known?: true)
      end

      it "counts an estimate-only generation as estimated" do
        start_turn
        priced_generation(40)
        metrics.call(type: :turn_completed)
        expect(metrics.cost.estimated).to be_within(1e-12).of(estimate_for(40))
        expect(metrics.cost).to have_attributes(reported: 0.0, known?: true)
      end

      it "counts the estimate of a reported 0 with a price (ModelPrice.estimate's rule)" do
        start_turn
        priced_generation(40, cost: 0)
        expect(metrics.cost.total).to be_within(1e-12).of(estimate_for(40))
        expect(metrics.cost.reported).to eq(0.0)
      end

      it "adds side requests, reported and estimated, to the total and to side" do
        start_turn
        priced_generation(40, cost: 0.25)
        metrics.add_side(side(cost: 0.01))
        side_estimate = Samagotchi::ModelPrice.estimate(Samagotchi::ModelPrice.new(**price), reported_cost: nil,
                                                        prompt_tokens: 1000, cached_tokens: 0, cache_write_tokens: 0,
                                                        completion_tokens: 20)
        metrics.add_side(side(price: Samagotchi::ModelPrice.new(**price)))

        cost = metrics.cost
        expect(cost.reported).to be_within(1e-12).of(0.26)
        expect(cost.estimated).to be_within(1e-12).of(side_estimate)
        expect(cost.side).to be_within(1e-12).of(0.01 + side_estimate)
        expect(cost.total).to be_within(1e-12).of(0.26 + side_estimate)
      end

      it "isn't known after an unpriced generation that reported no cost" do
        start_turn
        priced_generation(40, price: nil)
        expect(metrics.cost).to have_attributes(total: 0.0, known?: false)
      end

      it "isn't known after an unpriced side request alone" do
        metrics.add_side(side)
        expect(metrics.cost.known?).to be(false)
      end

      it "counts what earlier workers spent (load_persisted)" do
        dir = Dir.mktmpdir
        metrics.state_dir = dir
        start_turn("t1")
        priced_generation(40, cost: 0.25)
        metrics.call(type: :turn_completed)
        metrics.add_side(side(cost: 0.01))
        metrics.persist

        woken = frozen_metrics.tap { |m| m.state_dir = dir }
        woken.session_id = "speed"
        expect(woken.cost.reported).to be_within(1e-12).of(0.26)
        expect(woken.cost).to have_attributes(side: 0.01, known?: true)
      end
    end

    it "brings the sums back on reload, with the newest saved speeds; an older record counts as zeros" do
      dir = Dir.mktmpdir
      metrics.state_dir = dir
      start_turn("t1")
      metrics.call(type: :generation_started, iteration: 1)
      metrics.call(llama_chunk("a", 50, { "predicted_per_second" => 50.0, "predicted_ms" => 1000.0,
                                          "prompt_per_second" => 900.0 }))
      metrics.call(type: :generation_completed, iteration: 1)
      metrics.call(type: :turn_completed)
      start_turn("t2")
      estimated_generation(30, decode: 1.0, cost: 0.5)
      metrics.call(type: :turn_completed)
      metrics.persist
      path = File.join(Samagotchi::Session.session_dir("speed", state_dir: dir), "analytics.json")
      saved = JSON.parse(File.read(path))
      # An older record (no usage fields) after them.
      saved["turn_records"] << { "id" => "t0", "status" => "completed", "prompt_tokens_sum" => 10, "completion_tokens" => 2 }
      File.write(path, JSON.generate(saved))

      woken = frozen_metrics.tap { |m| m.state_dir = dir }
      woken.session_id = "speed"
      expect(woken.snapshot[:tokens]).to include(cached_sum: 280, cost_sum: 0.5, decode_tokens_sum: 80,
                                                 last_decode_tps: 30.0, tps_source: "estimate", last_prefill_tps: 900.0,
                                                 avg_decode_tps: 40.0, prompt_sum: 1310)
    end
  end

  it "counts retries and cancellations" do
    feed([
      { type: :turn_started, session_id: "sess-3", prompt: "x" },
      { type: :generation_retrying, attempt: 1, max_retries: 5, next_delay: 0.5, error_class: "Errno::ECONNREFUSED", error_message: "refused" },
      { type: :turn_canceled, cancellation_reason: :ctrl_c }
    ])

    snap = metrics.snapshot
    expect(snap[:retries]).to eq(1)
    expect(snap[:cancellations]).to eq(1)
    expect(snap[:turn_records].last).to include(status: "canceled", cancellation_reason: "ctrl_c")
  end

  # `retries` counts the network's; a looped turn is found by these.
  it "counts generations a plugin cut and ones the output cap ended, apart from retries" do
    feed([
      { type: :turn_started, session_id: "sess-cut", prompt: "x" },
      { type: :generation_started, iteration: 1 },
      { type: :generation_completed, iteration: 1, finish_reason: "stopped", stopped_by: "loop-guard" },
      { type: :generation_started, iteration: 2 },
      { type: :generation_completed, iteration: 2, finish_reason: "stopped", stopped_by: "steer" },
      { type: :generation_started, iteration: 3 },
      { type: :generation_completed, iteration: 3, finish_reason: "length" },
      { type: :turn_completed },
      { type: :turn_started, session_id: "sess-cut", prompt: "y" },
      { type: :generation_started, iteration: 1 },
      { type: :generation_completed, iteration: 1, finish_reason: "stopped", stopped_by: "loop-guard" }
    ])

    expect(metrics.snapshot[:turn_records].last).to include(cuts: 1, capped: 1, retries: 0)
    expect(metrics.snapshot).to include(cuts: 2, capped: 1, retries: 0)

    metrics.call(type: :turn_completed)
    expect(metrics.snapshot[:turn_records].last).to include(cuts: 1, capped: 0)
    expect(metrics.snapshot).to include(cuts: 2, capped: 1)
  end

  it "sums the thinking blocks a preserved-thinking recovery dropped into the turn record and the session" do
    feed([
      { type: :turn_started, session_id: "sess-drop", prompt: "x" },
      { type: :generation_started, iteration: 1 },
      { type: :generation_completed, iteration: 1, thinking_dropped: 3 },
      { type: :generation_started, iteration: 2 },
      { type: :generation_completed, iteration: 2 },
      { type: :turn_completed },
      { type: :turn_started, session_id: "sess-drop", prompt: "y" },
      { type: :generation_started, iteration: 1 },
      { type: :generation_completed, iteration: 1, thinking_dropped: 1 }
    ])

    expect(metrics.snapshot[:turn_records].last).to include(thinking_dropped: 3)
    expect(metrics.snapshot).to include(thinking_dropped: 4)

    metrics.call(type: :turn_completed)
    expect(metrics.snapshot).to include(thinking_dropped: 4)
  end

  it "saves no thinking_dropped on a turn record without a recovery" do
    feed([{ type: :turn_started, session_id: "sess-nodrop", prompt: "x" }, { type: :generation_started, iteration: 1 },
          { type: :generation_completed, iteration: 1 }, { type: :turn_completed }])

    expect(metrics.snapshot[:turn_records].last).not_to have_key(:thinking_dropped)
    expect(metrics.snapshot).to include(thinking_dropped: 0)
  end

  it "keeps who stopped a turn a plugin stopped" do
    feed([
      { type: :turn_started, session_id: "sess-3c", prompt: "x" },
      { type: :turn_canceled, cancellation_reason: :hook, cancelled_by: "loop-guard" },
      { type: :turn_started, session_id: "sess-3c", prompt: "y" },
      { type: :turn_canceled, cancellation_reason: :user }
    ])

    expect(metrics.snapshot[:turn_records].last(2)).to match([include(cancellation_reason: "hook", cancelled_by: "loop-guard"),
                                                              satisfy { |r| !r.key?(:cancelled_by) }])
  end

  # The web's reload draws the failure line the live turn_failed did
  # (turn_view.js failedLineHtml, format.js failedTurnText).
  it "keeps what a failed turn's line says on its record: the summary, else the message and class; the kept steps" do
    feed([
      { type: :turn_started, session_id: "sess-f", prompt: "x" },
      { type: :turn_failed, error_class: "Samagotchi::LLM::ProviderError", message: "HTTP 402\nbody", kept_steps: 3,
        summary: "402 Payment Required (openrouter)", error_kind: :payment, retryable: false },
      { type: :turn_started, session_id: "sess-f", prompt: "y" },
      { type: :turn_failed, error_class: "RuntimeError", message: "boom" }
    ])

    first, second = metrics.snapshot[:turn_records].last(2)
    expect(first).to include(status: "failed", failure: { summary: "402 Payment Required (openrouter)", kept_steps: 3 })
    expect(second[:failure]).to eq(message: "boom", error_class: "RuntimeError")
  end

  it "caps a failed turn's message on its record" do
    feed([
      { type: :turn_started, session_id: "sess-f2", prompt: "x" },
      { type: :turn_failed, error_class: "RuntimeError", message: "x" * 5000 }
    ])

    expect(metrics.snapshot[:turn_records].last[:failure][:message].length).to eq(described_class::FAILURE_MESSAGE_CHARS)
  end

  it "keeps no cancellation reason on a completed turn's record" do
    feed([
      { type: :turn_started, session_id: "sess-3b", prompt: "x" },
      { type: :turn_completed, result: double(respond_to?: false) }
    ])

    expect(metrics.snapshot[:turn_records].last).not_to have_key(:cancellation_reason)
  end

  it "commits partial generation tokens when a generation is canceled" do
    feed([
      { type: :turn_started, session_id: "cancelled-generation", prompt: "x" },
      { type: :generation_started, iteration: 1 },
      { type: :generation_chunk, iteration: 1, content: "partial", payload: { "timings" => { "prompt_n" => 20, "predicted_n" => 4 } } },
      { type: :generation_cancelled, iteration: 1, reason: :ctrl_c },
      { type: :turn_canceled, cancellation_reason: :ctrl_c }
    ])

    snap = metrics.snapshot
    expect(snap[:tokens]).to include(prompt_sum: 20, completion_sum: 4)
    expect(snap[:gen_latency_ms]).to be >= 0
  end

  it "estimates raw event content when a backend does not provide payload content" do
    feed([
      { type: :turn_started, session_id: "raw-content", prompt: "x" },
      { type: :generation_started, iteration: 1 },
      { type: :generation_chunk, iteration: 1, content: "thinking and answer", payload: nil },
      { type: :generation_completed, iteration: 1 },
      { type: :turn_completed, result: double(respond_to?: false) }
    ])

    expect(metrics.snapshot[:tokens][:completion_sum]).to eq(5)
  end

  it "persists a summary to the session directory" do
    metrics.session_id = "persist-sess"
    feed([
      { type: :turn_started, session_id: "persist-sess", prompt: "x" },
      { type: :turn_completed, result: double(respond_to?: false) }
    ])

    state_dir = Dir.mktmpdir
    expect(metrics.persist(state_dir: state_dir)).to be(true)
    dir = Samagotchi::Session.session_dir("persist-sess", state_dir: state_dir)
    expect(File.exist?(File.join(dir, "analytics.json"))).to be(true)
  end

  it "swallows a failed persist, logging each error class once" do
    metrics.state_dir = Dir.mktmpdir
    metrics.session_id = "fail-sess"
    errors = [Errno::ENOSPC.new, Errno::ENOSPC.new, Errno::EACCES.new]
    allow(Samagotchi::AtomicFile).to receive(:write) { raise errors.shift }
    allow(Samagotchi::Log).to receive(:warn)

    expect(Array.new(3) { metrics.persist }).to eq([false, false, false])
    expect(Samagotchi::Log).to have_received(:warn).twice
    expect(Samagotchi::Log).to have_received(:warn)
      .with(:turn, "analytics_persist_failed", error: "Errno::ENOSPC", msg: a_string_including("No space"))
    expect(Samagotchi::Log).to have_received(:warn)
      .with(:turn, "analytics_persist_failed", error: "Errno::EACCES", msg: a_string_including("Permission"))
  end

  it "still returns false when logging the failure raises, or the persist re-enters" do
    metrics.state_dir = Dir.mktmpdir
    metrics.session_id = "fail-sess"
    allow(Samagotchi::AtomicFile).to receive(:write).and_raise(Errno::ENOSPC)
    allow(Samagotchi::Log).to receive(:warn).and_raise(IOError, "log closed")
    expect(metrics.persist).to be(false)

    inner = nil
    allow(Samagotchi::AtomicFile).to receive(:write) { inner = metrics.persist }
    expect { metrics.persist }.not_to raise_error
    expect(inner).to be(false) # a ThreadError from the re-entered mutex
  end

  # Two persists on two threads (a turn's end, a checkpoint, a side request
  # between turns) never land out of order: the older snapshot can't be
  # written over the newer one.
  it "serializes persists, so a later persist's snapshot is written last" do
    state_dir = Dir.mktmpdir
    metrics.state_dir = state_dir
    metrics.session_id = "order-sess"
    metrics.memory_index = { system: { tokens: 1, lines: 1 } }
    entered = Queue.new
    gate = Queue.new
    first = true
    allow(Samagotchi::AtomicFile).to receive(:write).and_wrap_original do |original, *args|
      if first
        first = false
        entered << true
        gate.pop
      end
      original.call(*args)
    end

    older = Thread.new { metrics.persist }
    entered.pop
    metrics.memory_index = { system: { tokens: 2, lines: 2 } }
    newer = Thread.new { metrics.persist }
    blocked = wait_until(timeout: 1, interval: 0.005) { newer.status == "sleep" }
    gate << true
    [older, newer].each(&:join)

    expect(blocked).to be(true)
    saved = JSON.parse(File.read(File.join(state_dir, "order-sess", "analytics.json")))
    expect(saved["memory_index"]).to eq("system" => { "tokens" => 2, "lines" => 2 })
  end

  it "records completed turn and tool wall-clock durations with injected clocks" do
    monotonic = 10.0
    wall_time = Time.utc(2026, 9, 21, 10, 0, 0)
    metrics = described_class.new(
      clock: -> { monotonic },
      wall_clock: -> { wall_time }
    )

    metrics.call(type: :turn_started, session_id: "timed", prompt: "x")
    monotonic += 0.25
    wall_time += 0.25
    metrics.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "read")
    monotonic += 0.5
    wall_time += 0.5
    metrics.call(type: :tool_call_completed, iteration: 1, call_index: 1, tool: "read", activity: { status: "ok" })
    monotonic += 1.25
    wall_time += 1.25
    metrics.call(type: :turn_completed, result: double(respond_to?: false))

    snap = metrics.snapshot
    expect(snap[:turn_records]).to include(hash_including(status: "completed", duration_ms: 2000))
    expect(snap[:tool_records]).to include(hash_including(tool: "read", status: "ok", duration_ms: 500))
    expect(snap[:active_turn]).to be_nil
    expect(snap[:active_tools]).to be_empty
  end

  it "saves a guardrail-denied call's record as blocked, not as an error (the web's reload reads it)" do
    metrics = frozen_metrics
    metrics.call(type: :turn_started, session_id: "denied", prompt: "x")
    metrics.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "execute")
    metrics.call(type: :tool_call_completed, iteration: 1, call_index: 1, tool: "execute",
                 activity: { status: "blocked" })
    metrics.call(type: :turn_canceled, reason: "hook")

    snap = metrics.snapshot
    expect(snap[:tool_records]).to contain_exactly(hash_including(tool: "execute", status: "blocked"))
    expect(snap[:turn_records].last).to include(tool_errors: 0)
  end

  it "leaves a guardrail approval wait out of a tool record's duration" do
    monotonic = 10.0
    metrics = described_class.new(clock: -> { monotonic })
    metrics.call(type: :turn_started, session_id: "timed", prompt: "x")
    metrics.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "shell")
    monotonic += 3.0
    metrics.call(type: :tool_call_completed, iteration: 1, call_index: 1, tool: "shell", status: "ok", waited_ms: 2_750)
    metrics.call(type: :tool_call_started, iteration: 1, call_index: 2, tool: "shell")
    monotonic += 0.1
    metrics.call(type: :tool_call_completed, iteration: 1, call_index: 2, tool: "shell", status: "ok", waited_ms: 9_999)

    expect(metrics.snapshot[:tool_records].map { |r| r[:duration_ms] }).to eq([250, 0])
  end

  # A worker's turn checkpoint (TurnCheckpoint, at most every 10 s) saves
  # the running turn's record so far, as the turn a SIGKILL now would
  # leave: the next worker loads it (and settles the turn); the turn's own
  # end writes over it.
  describe "persist(running_turn: true)" do
    let(:state_dir) { Dir.mktmpdir }

    def run_one_generation(collector)
      collector.state_dir = state_dir
      collector.call(type: :turn_started, session_id: "killed", prompt: "x", turn_id: "turn-k")
      collector.call(type: :generation_started, iteration: 1)
      collector.call(type: :generation_chunk, iteration: 1, content: "some answer",
                     payload: { "timings" => { "prompt_n" => 20, "predicted_n" => 40, "predicted_per_second" => 50.0, "predicted_ms" => 800 } })
      collector.call(type: :generation_completed, iteration: 1)
    end

    it "saves the running turn's record as canceled by worker_stopped, with its tokens and speed; the next collector loads it" do
      run_one_generation(metrics)
      expect(metrics.persist(running_turn: true)).to be(true)

      woken = frozen_metrics
      woken.state_dir = state_dir
      woken.session_id = "killed"
      record = woken.saved_snapshot[:turn_records].last
      expect(record).to include(id: "turn-k", status: "canceled", cancellation_reason: "worker_stopped",
                                prompt_tokens_sum: 20, completion_tokens: 40, decode_tps: 50.0, generations: 1)
      expect(woken.snapshot).to include(turns: 1, cancellations: 1)
      expect(woken.snapshot[:tokens]).to include(prompt_sum: 20, completion_sum: 40)
      # The running collector itself still counts the turn as running.
      expect(metrics.snapshot).to include(turns: 1, cancellations: 0)
    end

    it "is written over by the turn's own end" do
      run_one_generation(metrics)
      metrics.persist(running_turn: true)
      metrics.call(type: :turn_completed, result: double(respond_to?: false))
      metrics.persist

      records = JSON.parse(File.read(File.join(Samagotchi::Session.session_dir("killed", state_dir: state_dir), "analytics.json")))
      expect(records["turn_records"].map { |r| [r["id"], r["status"]] }).to eq([%w[turn-k completed]])
      expect(records["cancellations"]).to eq(0)
    end
  end

  it "keeps the earlier records in its state dir when a later worker persists analytics" do
    state_dir = Dir.mktmpdir
    first = frozen_metrics
    first.state_dir = state_dir
    first.call(type: :turn_started, session_id: "resumed", prompt: "one")
    first.call(type: :turn_completed, result: double(respond_to?: false))
    first.persist

    second = frozen_metrics
    second.state_dir = state_dir
    second.call(type: :turn_started, session_id: "resumed", prompt: "two")
    second.call(type: :turn_completed, result: double(respond_to?: false))
    second.persist

    path = File.join(Samagotchi::Session.session_dir("resumed", state_dir: state_dir), "analytics.json")
    expect(JSON.parse(File.read(path)).fetch("turn_records").size).to eq(2)
  end

  it "brings back the served model a woken collector's session last reported" do
    state_dir = Dir.mktmpdir
    first = frozen_metrics
    first.state_dir = state_dir
    first.call(type: :turn_started, session_id: "woken", prompt: "one")
    first.call(type: :generation_started, iteration: 1)
    first.call(type: :generation_completed, iteration: 1, served_model: "ornith", requested_model: "qwen")
    first.call(type: :turn_completed)
    first.persist

    woken = frozen_metrics
    woken.state_dir = state_dir
    woken.session_id = "woken"

    expect(woken.served_report).to eq(served_model: "ornith", served_model_for: "qwen")
    expect(woken.snapshot).to include(served_model: "ornith", served_model_for: "qwen")
  end

  it "saves a call still running when its turn is canceled as stopped, so the records match the count" do
    state_dir = Dir.mktmpdir
    metrics = frozen_metrics
    metrics.state_dir = state_dir
    metrics.call(type: :turn_started, session_id: "cut", prompt: "x")
    metrics.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "read")
    metrics.call(type: :tool_call_completed, iteration: 1, call_index: 1, tool: "read", status: "ok")
    metrics.call(type: :tool_call_started, iteration: 1, call_index: 2, tool: "execute")
    metrics.call(type: :turn_canceled, cancellation_reason: :user)

    snap = metrics.snapshot
    expect(snap[:tool_records].map { |r| [r[:tool], r[:status]] }).to eq([%w[read ok], %w[execute stopped]])
    expect(snap[:tool_calls_total]).to eq(2)
    expect(snap[:tool_calls_by_tool]).to eq("read" => 1, "execute" => 1)
    expect(snap[:turn_records].last[:tool_calls]).to eq(snap[:tool_records].size)
    expect(snap[:active_tools]).to be_empty
    metrics.persist

    woken = frozen_metrics
    woken.state_dir = state_dir
    woken.session_id = "cut"
    expect(woken.snapshot).to include(tool_calls_total: 2, tool_calls_by_tool: { "read" => 1, "execute" => 1 })
  end

  it "saves a call still running when its turn fails as canceled: no one stopped it" do
    metrics = frozen_metrics
    metrics.call(type: :turn_started, session_id: "broke", prompt: "x")
    metrics.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "execute")
    metrics.call(type: :turn_failed, error: "boom")

    snap = metrics.snapshot
    expect(snap[:tool_records].map { |r| [r[:tool], r[:status]] }).to eq([%w[execute canceled]])
    expect(snap[:tool_calls_total]).to eq(1)
  end

  it "measures the session's duration from its first start, across collectors" do
    state_dir = Dir.mktmpdir
    wall_time = Time.utc(2026, 9, 21, 10, 0, 0)
    first = described_class.new(wall_clock: -> { wall_time })
    first.state_dir = state_dir
    first.call(type: :turn_started, session_id: "long", prompt: "one")
    first.call(type: :turn_completed)
    first.persist

    wall_time += 3600
    woken = described_class.new(wall_clock: -> { wall_time })
    woken.state_dir = state_dir
    woken.call(type: :turn_started, session_id: "long", prompt: "two")
    wall_time += 2

    snap = woken.snapshot
    expect(snap[:started_at]).to eq("2026-09-21T10:00:00.000Z")
    expect(snap[:session_duration_ms]).to eq(3_602_000)
  end

  # A worker that stops (idle exit, `chi sessions stop`) and wakes again is
  # a new collector for the same session: its totals must cover both.
  it "keeps the aliased-call count across a save and a fresh collector's load" do
    state_dir = Dir.mktmpdir
    first = frozen_metrics.tap { |m| m.state_dir = state_dir }
    first.session_id = "aliased"
    [
      { type: :turn_started, session_id: "aliased", prompt: "p" },
      { type: :generation_started, iteration: 1 },
      { type: :tool_call_started, iteration: 1, call_index: 1, tool: "execute" },
      { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "execute", status: "ok",
        activity: { tool: "execute", status: "ok", called_as: "bash" } },
      { type: :generation_completed, iteration: 1 },
      { type: :turn_completed }
    ].each { |event| first.call(event) }
    first.persist

    written = JSON.parse(File.read(File.join(Samagotchi::Session.session_dir("aliased", state_dir: state_dir),
                                             "analytics.json")))
    expect(written["tool_calls_aliased"]).to eq("bash" => 1)
    expect(written["tool_records"].first["called_as"]).to eq("bash")

    second = frozen_metrics.tap { |m| m.state_dir = state_dir }
    second.session_id = "aliased"
    expect(second.snapshot[:tool_calls_aliased]).to eq("bash" => 1)
  ensure
    FileUtils.rm_rf(state_dir) if state_dir
  end

  it "totals every process's turns when two collectors persist to one dir in turn" do
    xdg = Dir.mktmpdir
    original = ENV["XDG_STATE_HOME"]
    ENV["XDG_STATE_HOME"] = xdg
    turn = lambda do |metrics, prompt_tokens, tool|
      metrics.session_id = "restarted"
      metrics.call(type: :turn_started, session_id: "restarted", prompt: "p")
      metrics.call(type: :generation_started, iteration: 1)
      metrics.call(type: :generation_chunk, iteration: 1, content: "a",
                   payload: { "usage" => { "prompt_tokens" => prompt_tokens, "completion_tokens" => 10 } })
      metrics.call(type: :tool_dispatch_started, iteration: 1, call_count: 1)
      metrics.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: tool)
      metrics.call(type: :tool_call_completed, iteration: 1, call_index: 1, tool: tool, status: "ok")
      metrics.call(type: :generation_completed, iteration: 1)
      metrics.call(type: :turn_completed)
      metrics.persist
    end

    turn.call(frozen_metrics, 100, "read")
    second = frozen_metrics
    turn.call(second, 150, "shell")

    path = File.join(Samagotchi::Session.session_dir("restarted"), "analytics.json")
    written = JSON.parse(File.read(path))
    expect(written["turns"]).to eq(2)
    expect(written["iterations_total"]).to eq(2)
    expect(written["tool_calls_total"]).to eq(2)
    expect(written["tool_calls_by_tool"]).to eq("read" => 1, "shell" => 1)
    expect(written["tokens"]).to include("prompt_sum" => 250, "completion_sum" => 20, "source" => "server")
    expect(second.snapshot).to include(turns: 2, tool_calls_total: 2)
  ensure
    ENV["XDG_STATE_HOME"] = original
  end

  # The live snapshot (Bridge /state, /snapshot, SSE frames) carries the
  # totals and only the recent records; analytics.json keeps the history.
  describe "the live snapshot's records" do
    let(:state_dir) { Dir.mktmpdir }
    let(:metrics) { frozen_metrics.tap { |m| m.state_dir = state_dir } }

    def run_turn(metrics, n, tools: 2, sid: "live")
      metrics.call(type: :turn_started, session_id: sid, prompt: "p#{n}", turn_id: "t#{n}")
      metrics.call(type: :generation_started, iteration: 1)
      metrics.call(type: :generation_chunk, iteration: 1, content: "a",
                   payload: { "usage" => { "prompt_tokens" => 100, "completion_tokens" => 10 } })
      metrics.call(type: :tool_dispatch_started, iteration: 1, call_count: tools)
      tools.times do |i|
        metrics.call(type: :tool_call_started, iteration: 1, call_index: i + 1, tool: "read")
        metrics.call(type: :tool_call_completed, iteration: 1, call_index: i + 1, tool: "read", status: "ok")
      end
      metrics.call(type: :generation_completed, iteration: 1)
      metrics.call(type: :turn_completed)
    end

    def saved(sid = "live")
      JSON.parse(File.read(File.join(Samagotchi::Session.session_dir(sid, state_dir: state_dir), "analytics.json")))
    end

    it "holds the newest finished turn's records once saved; the file holds them all" do
      (1..3).each do |n|
        run_turn(metrics, n)
        expect(metrics.persist).to be(true)
      end

      snap = metrics.snapshot
      expect(snap[:turn_records].map { |r| r[:id] }).to eq(["t3"])
      expect(snap[:tool_records].map { |r| r[:id] }).to eq(["t3:1:1", "t3:1:2"])
      expect(snap).to include(turns: 3, tool_calls_total: 6, iterations_total: 3)
      expect(saved["turn_records"].map { |r| r["id"] }).to eq(%w[t1 t2 t3])
      expect(saved["tool_records"].size).to eq(6)
      expect(saved).to include("turns" => 3, "tool_calls_total" => 6)
    end

    it "holds the newest turn between its end and its save" do
      run_turn(metrics, 1)
      metrics.persist
      run_turn(metrics, 2)

      expect(metrics.snapshot[:turn_records].map { |r| r[:id] }).to eq(["t2"])
      expect(metrics.snapshot[:tool_records].map { |r| r[:turn_id] }.uniq).to eq(["t2"])
    end

    it "holds the running turn's finished calls" do
      run_turn(metrics, 1)
      metrics.persist
      metrics.call(type: :turn_started, session_id: "live", prompt: "p2", turn_id: "t2")
      metrics.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "read")
      metrics.call(type: :tool_call_completed, iteration: 1, call_index: 1, tool: "read", status: "ok")
      metrics.call(type: :tool_call_started, iteration: 1, call_index: 2, tool: "grep")

      snap = metrics.snapshot
      expect(snap[:turn_records].map { |r| r[:id] }).to eq(["t1"])
      expect(snap[:tool_records].map { |r| r[:id] }).to eq(["t1:1:1", "t1:1:2", "t2:1:1"])
      expect(snap[:active_tools].map { |r| r[:id] }).to eq(["t2:1:2"])
    end

    it "keeps unsaved turns while saving fails, the newest 20 at most" do
      blocked = frozen_metrics.tap { |m| m.state_dir = File.join(state_dir, "file") }
      File.write(File.join(state_dir, "file"), "not a dir")
      run_turn(blocked, 1, sid: "blocked")
      run_turn(blocked, 2, sid: "blocked")
      expect(blocked.persist).to be(false)
      expect(blocked.snapshot[:turn_records].map { |r| r[:id] }).to eq(%w[t1 t2])

      (3..25).each { |n| run_turn(blocked, n, sid: "blocked") }
      snap = blocked.snapshot
      expect(snap[:turn_records].map { |r| r[:id] }).to eq((6..25).map { |n| "t#{n}" })
      expect(snap[:tool_records].map { |r| r[:turn_id] }.uniq).to eq((6..25).map { |n| "t#{n}" })
      expect(snap).to include(turns: 25, tool_calls_total: 50)
    end

    it "caps a collector with no session id at 20 turns" do
      bare = frozen_metrics
      (1..22).each { |n| run_turn(bare, n, tools: 0, sid: nil) }
      expect(bare.persist).to be(false)
      expect(bare.snapshot[:turn_records].size).to eq(20)
      expect(bare.snapshot[:turns]).to eq(22)
    end

    it "a woken collector has no records but every turn in its totals, and saves them all" do
      first = frozen_metrics.tap { |m| m.state_dir = state_dir }
      (1..5).each do |n|
        run_turn(first, n)
        first.persist
      end
      first.call(type: :turn_started, session_id: "live", prompt: "p6", turn_id: "t6")
      first.call(type: :generation_retrying, attempt: 1)
      first.call(type: :turn_canceled, cancellation_reason: :user)
      first.persist

      woken = frozen_metrics.tap { |m| m.state_dir = state_dir }
      woken.session_id = "live"
      snap = woken.snapshot
      expect(snap[:turn_records]).to eq([])
      expect(snap[:tool_records]).to eq([])
      expect(snap).to include(turns: 6, tool_calls_total: 10, tool_calls_by_tool: { "read" => 10 },
                              iterations_total: 5, retries: 1, cancellations: 1,
                              tokens: hash_including(prompt_sum: 500, completion_sum: 50, source: "server"))
      expect(snap[:context]).to include(used_tokens: 110)

      run_turn(woken, 7)
      expect(woken.snapshot[:turn_records].map { |r| r[:id] }).to eq(["t7"])
      woken.persist
      expect(saved["turn_records"].map { |r| r["id"] }).to eq(%w[t1 t2 t3 t4 t5 t6 t7])
      expect(saved["tool_records"].size).to eq(12)
      expect(woken.snapshot[:turn_records].map { |r| r[:id] }).to eq(["t7"])
    end
  end

  # :generation_started's model_ref (Engine#generation_model_ref) names the
  # model a turn ran on; the first generation after a switch prefilled the
  # history on the new model, and its record says how much.
  describe "the turn's model and a switch's prefill" do
    let(:price) { { input: 2.0, cache_read: 0.5, cache_write: 4.0, output: 10.0 } }

    def turn(ref, prompt: 1000, cached: 0, cache_write: nil, generations: 1, price: nil, id: nil)
      events = [{ type: :turn_started, session_id: "sess-m", prompt: "p", turn_id: id }]
      generations.times do |n|
        usage = { "prompt_tokens" => prompt, "completion_tokens" => 10,
                  "prompt_tokens_details" => { "cached_tokens" => cached, "cache_write_tokens" => cache_write }.compact }
        events << { type: :generation_started, iteration: n + 1, model_ref: ref, price: price }.compact
        events << { type: :generation_chunk, iteration: n + 1, content: "a", payload: { "usage" => usage } }
        events << { type: :generation_completed, iteration: n + 1 }
      end
      feed(events + [{ type: :turn_completed }])
      metrics.snapshot[:turn_records].last
    end

    it "records the turn's model ref, the first generation's" do
      feed([{ type: :turn_started, session_id: "sess-m", prompt: "p" },
            { type: :generation_started, iteration: 1, model_ref: "a:one" },
            { type: :generation_completed, iteration: 1 },
            { type: :generation_started, iteration: 2, model_ref: "b:two" },
            { type: :generation_completed, iteration: 2 },
            { type: :turn_completed }])

      expect(metrics.snapshot[:turn_records].last[:model_ref]).to eq("a:one")
    end

    it "gives the first turn on a model no switch prefill, nor a later turn on it" do
      expect(turn("a:one", prompt: 5000)).not_to include(:switch_prefill_tokens)
      expect(turn("a:one", prompt: 6000)).not_to include(:switch_prefill_tokens)
    end

    it "records the uncached prompt of the first generation after a switch, with its cost estimated from the price" do
      turn("a:one")
      record = turn("b:two", prompt: 5000, cached: 1000, cache_write: 2000, generations: 2, price: price)

      expect(record[:switch_prefill_tokens]).to eq(4000)
      # 2000 uncached at 2.0, 1000 cached reads at 0.5, 2000 writes at 4.0; no completion.
      expect(record[:switch_prefill_cost_estimate]).to be_within(1e-9).of(((2000 * 2.0) + (1000 * 0.5) + (2000 * 4.0)) / 1e6)
      expect(turn("b:two", prompt: 6000)).not_to include(:switch_prefill_tokens)
    end

    it "records the tokens alone without a price" do
      turn("a:one")
      record = turn("b:two", prompt: 3000)

      expect(record).to include(switch_prefill_tokens: 3000)
      expect(record).not_to include(:switch_prefill_cost_estimate)
    end

    it "counts each switch of A -> B -> A, under the model switched to" do
      turn("a:one")
      to_b = turn("b:two", prompt: 2000)
      back = turn("a:one", prompt: 2500, cached: 300)

      expect([to_b[:switch_prefill_tokens], back[:switch_prefill_tokens]]).to eq([2000, 2200])
    end

    it "skips a prefill under REPREFILL_MIN_TOKENS (a server that kept the cache)" do
      turn("a:one")
      expect(turn("b:two", prompt: 2000, cached: 1950)).not_to include(:switch_prefill_tokens)
    end

    it "skips a first generation with estimated tokens only" do
      turn("a:one")
      feed([{ type: :turn_started, session_id: "sess-m", prompt: "p" },
            { type: :generation_started, iteration: 1, model_ref: "b:two" },
            { type: :generation_chunk, iteration: 1, content: "x" * 400, payload: nil },
            { type: :generation_completed, iteration: 1 },
            { type: :turn_completed }])

      expect(metrics.snapshot[:turn_records].last).to include(model_ref: "b:two")
      expect(metrics.snapshot[:turn_records].last).not_to include(:switch_prefill_tokens)
    end

    # A turn stopped before any generation (Stop during probes) names no
    # model: it is never a switch, and the next turn compares with the last
    # turn that named one.
    it "treats a turn with no ref as none: the next one on the same model is no switch" do
      turn("a:one")
      turn("b:two", prompt: 2000)
      feed([{ type: :turn_started, session_id: "sess-m", prompt: "p" }, { type: :turn_canceled, cancellation_reason: :user }])
      expect(metrics.snapshot[:turn_records].last[:model_ref]).to be_nil

      expect(turn("b:two", prompt: 3000)).not_to include(:switch_prefill_tokens)
    end

    it "never takes a legacy session's first ref'd turn for a switch" do
      feed([{ type: :turn_started, session_id: "sess-m", prompt: "p" },
            { type: :generation_started, iteration: 1 },
            { type: :generation_completed, iteration: 1 },
            { type: :turn_completed }])

      expect(turn("b:two", prompt: 3000)).not_to include(:switch_prefill_tokens)
    end

    it "keeps the last model across a woken collector" do
      state_dir = Dir.mktmpdir
      first = frozen_metrics.tap { |m| m.state_dir = state_dir }
      first.call(type: :turn_started, session_id: "sess-w", prompt: "p")
      first.call(type: :generation_started, iteration: 1, model_ref: "a:one")
      first.call(type: :turn_completed)
      first.persist

      woken = frozen_metrics.tap { |m| m.state_dir = state_dir }
      [{ type: :turn_started, session_id: "sess-w", prompt: "p" },
       { type: :generation_started, iteration: 1, model_ref: "b:two" },
       { type: :generation_chunk, iteration: 1, content: "a", payload: { "usage" => { "prompt_tokens" => 900 } } },
       { type: :generation_completed, iteration: 1 },
       { type: :turn_completed }].each { |e| woken.call(e) }

      expect(woken.snapshot[:turn_records].last).to include(model_ref: "b:two", switch_prefill_tokens: 900)
    end

    it "saves the running turn's model and prefill with persist(running_turn: true)" do
      state_dir = Dir.mktmpdir
      metrics.state_dir = state_dir
      turn("a:one")
      feed([{ type: :turn_started, session_id: "sess-m", prompt: "p", turn_id: "running" },
            { type: :generation_started, iteration: 1, model_ref: "b:two" },
            { type: :generation_chunk, iteration: 1, content: "a", payload: { "usage" => { "prompt_tokens" => 700 } } },
            { type: :generation_completed, iteration: 1 }])
      metrics.persist(running_turn: true)

      saved = described_class.saved_turn_record(Samagotchi::Session.session_dir("sess-m", state_dir: state_dir), "running")
      expect(saved).to include("model_ref" => "b:two", "switch_prefill_tokens" => 700)
    end
  end

  # The snapshot's model_segments split the totals by model, in order
  # (ModelSegment): /stats and the web tooltip's rows.
  describe "model_segments" do
    def turn(ref, prompt: 1000, completion: 10, cost: nil, finish: true, id: nil)
      usage = { "prompt_tokens" => prompt, "completion_tokens" => completion, "cost" => cost }.compact
      events = [{ type: :turn_started, session_id: "sess-s", prompt: "p", turn_id: id },
                { type: :generation_started, iteration: 1, model_ref: ref }.compact,
                { type: :generation_chunk, iteration: 1, content: "a", payload: { "usage" => usage } },
                { type: :generation_completed, iteration: 1 }]
      feed(finish ? events + [{ type: :turn_completed }] : events)
    end

    def rows = metrics.snapshot[:model_segments]

    it "is empty with one model, and always present" do
      expect(metrics.snapshot).to include(model_segments: [])
      2.times { turn("a:one") }
      expect(rows).to eq([])
    end

    it "splits A x2 -> B x2 -> A into three rows in order, each switch's prefill under the model switched to" do
      2.times { turn("a:one", prompt: 1000, completion: 10, cost: 0.25) }
      2.times { turn("b:two", prompt: 3000, completion: 20) }
      turn("a:one", prompt: 4000, completion: 5)

      expect(rows.map { |row| row.slice(:model_ref, :turns, :prompt_sum, :completion_sum, :prefill_tokens) })
        .to eq([{ model_ref: "a:one", turns: 2, prompt_sum: 2000, completion_sum: 20, prefill_tokens: 0 },
                { model_ref: "b:two", turns: 2, prompt_sum: 6000, completion_sum: 40, prefill_tokens: 3000 },
                { model_ref: "a:one", turns: 1, prompt_sum: 4000, completion_sum: 5, prefill_tokens: 4000 }])
      expect(rows.first[:cost_sum]).to eq(0.5)
      expect(rows.map { |row| row[:ended_at] }).to all(be_a(String))
    end

    it "keeps a turn with no ref (stopped before it asked) in the segment before it" do
      turn("a:one")
      turn("b:two")
      feed([{ type: :turn_started, session_id: "sess-s", prompt: "p" }, { type: :turn_canceled, cancellation_reason: :user }])
      turn("b:two")

      expect(rows.map { |row| row.slice(:model_ref, :turns) }).to eq([{ model_ref: "a:one", turns: 1 },
                                                                      { model_ref: "b:two", turns: 3 }])
    end

    it "puts a legacy session's turns with no ref in one leading row with no ref" do
      2.times do
        feed([{ type: :turn_started, session_id: "sess-s", prompt: "p" }, { type: :generation_started, iteration: 1 },
              { type: :generation_completed, iteration: 1 }, { type: :turn_completed }])
      end
      turn("b:two")

      expect(rows.map { |row| row.slice(:model_ref, :turns, :prefill_tokens) })
        .to eq([{ model_ref: nil, turns: 2, prefill_tokens: 0 }, { model_ref: "b:two", turns: 1, prefill_tokens: 0 }])
    end

    it "counts the running turn in its model's row, a new one when it switched, with no end" do
      turn("a:one")
      turn("b:two", prompt: 2000, finish: false)

      expect(rows.map { |row| row.slice(:model_ref, :turns, :prompt_sum, :prefill_tokens, :ended_at) })
        .to eq([{ model_ref: "a:one", turns: 1, prompt_sum: 1000, prefill_tokens: 0, ended_at: rows.first[:ended_at] },
                { model_ref: "b:two", turns: 1, prompt_sum: 2000, prefill_tokens: 2000, ended_at: nil }])
    end

    it "reports the rows with each generation's end (finish_generation)" do
      turn("a:one")
      feed([{ type: :turn_started, session_id: "sess-s", prompt: "p" },
            { type: :generation_started, iteration: 1, model_ref: "b:two" },
            { type: :generation_chunk, iteration: 1, content: "a", payload: { "usage" => { "prompt_tokens" => 700 } } }])

      report = metrics.finish_generation
      expect(report.model_segments.map { |row| row.slice(:model_ref, :prompt_sum) })
        .to eq([{ model_ref: "a:one", prompt_sum: 1000 }, { model_ref: "b:two", prompt_sum: 700 }])
    end

    it "folds the oldest rows into one over the cap, saying how many it holds" do
      refs = %w[a:one b:two] * 4
      refs.each_with_index { |ref, n| turn(ref, prompt: 100 * (n + 1)) }

      expect(rows.size).to eq(described_class::ModelSegment::CAP)
      expect(rows.first).to include(model_ref: nil, folded_segments: 3, turns: 3, prompt_sum: 100 + 200 + 300)
      expect(rows.drop(1).map { |row| row[:model_ref] }).to eq(%w[b:two a:one b:two a:one b:two])
      expect(rows.sum { |row| row[:prompt_sum] }).to eq(metrics.snapshot[:tokens][:prompt_sum])
    end

    it "rebuilds the rows from analytics.json for a woken collector and a saved snapshot" do
      state_dir = Dir.mktmpdir
      metrics.state_dir = state_dir
      turn("a:one")
      turn("b:two")
      metrics.persist

      woken = frozen_metrics.tap { |m| m.state_dir = state_dir }
      woken.session_id = "sess-s"
      expect(woken.saved_snapshot[:model_segments].map { |row| row[:model_ref] }).to eq(%w[a:one b:two])
      expect(woken.snapshot[:model_segments]).to eq(metrics.snapshot[:model_segments])
    end
  end

  # The totals are running counters; they must equal the sums over every
  # record (what #snapshot computed before), mid-turn, after a reload too.
  describe "the running totals" do
    def num(records, key) = records.sum { |r| r[key].is_a?(Numeric) ? r[key] : 0 }

    # The totals recomputed over the collector's full record lists and the
    # running turn (spec-only: reads the private state).
    def recomputed(metrics)
      records = metrics.instance_variable_get(:@turn_records)
      done = metrics.instance_variable_get(:@tool_records)
      turn = metrics.instance_variable_get(:@turn)
      tools = done + (turn ? turn.tool_calls_by_id.values : [])
      kinds = (records.map { |r| r[:token_source] } + (turn&.token_sources || [])).compact.map(&:to_s)
                                                                                  .flat_map { |k| k == "mixed" ? %w[server estimate] : [k] }.uniq
      {
        turns: records.size + (turn ? 1 : 0),
        cancellations: records.count { |r| r[:status] == "canceled" },
        tokens: { prompt_sum: num(records, :prompt_tokens_sum) + (turn&.prompt_sum || 0),
                  completion_sum: num(records, :completion_tokens) + (turn&.completion_sum || 0),
                  cached_sum: num(records, :cached_tokens_sum) + (turn&.cached_sum || 0),
                  reasoning_sum: num(records, :reasoning_tokens) + (turn&.reasoning_sum || 0),
                  cost_sum: num(records, :cost) + (turn&.cost_sum || 0),
                  source: kinds.size > 1 ? "mixed" : kinds.first },
        tool_calls_total: tools.size,
        tool_calls_by_tool: tools.map { |t| t[:tool].to_s }.reject(&:empty?).tally,
        tool_errors: done.count { |t| t[:status] == "error" },
        iterations_total: num(records, :iterations) + (turn&.iteration_count || 0),
        gen_latency_ms: (num(records, :gen_ms) + (turn&.gen_latency_accum || 0)).round,
        retries: num(records, :retries) + (turn&.retries || 0)
      }
    end

    def totals(snapshot)
      snapshot.slice(*recomputed_keys).merge(tokens: snapshot[:tokens].slice(*recomputed_token_keys))
    end

    def recomputed_token_keys = %i[prompt_sum completion_sum cached_sum reasoning_sum cost_sum source]

    def recomputed_keys = %i[turns cancellations tokens tool_calls_total tool_calls_by_tool tool_errors
                             iterations_total gen_latency_ms retries]

    # The model segments add up to the totals: tokens, cost and turns.
    def segment_sums(snapshot)
      rows = snapshot[:model_segments]
      return nil if rows.empty?

      keys = %i[prompt_sum completion_sum cached_sum cost_sum]
      keys.to_h { |key| [key, rows.sum { |row| row[key] }] }.merge(turns: rows.sum { |row| row[:turns] })
    end

    def expected_sums(snapshot)
      snapshot[:tokens].slice(:prompt_sum, :completion_sum, :cached_sum, :cost_sum).merge(turns: snapshot[:turns])
    end

    def random_events(rng, turn_id)
      events = [{ type: :turn_started, session_id: "random", prompt: "p", turn_id: turn_id }]
      ref = [nil, "a:one", "a:one", "b:two", "c:three"].sample(random: rng)
      rng.rand(0..3).times do |iteration|
        events << { type: :generation_started, iteration: iteration + 1, model_ref: ref }.compact
        events << { type: :generation_retrying, attempt: 1 } if rng.rand < 0.2
        events << if rng.rand < 0.7
                    { type: :generation_chunk, iteration: iteration + 1, content: "a",
                      payload: { "usage" => { "prompt_tokens" => rng.rand(1..500), "completion_tokens" => rng.rand(1..50),
                                              "prompt_tokens_details" => { "cached_tokens" => rng.rand(0..100) },
                                              "completion_tokens_details" => { "reasoning_tokens" => rng.rand(0..20) },
                                              # Quarters add up exactly in any order.
                                              "cost" => rng.rand < 0.5 ? rng.rand(0..8) * 0.25 : nil } } }
                  else
                    { type: :generation_chunk, iteration: iteration + 1, content: "x" * rng.rand(1..80), payload: nil }
                  end
        events << { type: :generation_completed, iteration: iteration + 1 }
        calls = rng.rand(0..3)
        next if calls.zero?

        events << { type: :tool_dispatch_started, iteration: iteration + 1, call_count: calls }
        calls.times do |index|
          tool = %w[read execute grep].sample(random: rng)
          events << { type: :tool_call_started, iteration: iteration + 1, call_index: index + 1, tool: tool }
          events << { type: :tool_call_completed, iteration: iteration + 1, call_index: index + 1, tool: tool,
                      status: %w[ok ok error blocked].sample(random: rng) }
        end
      end
      events << [{ type: :turn_completed }, { type: :turn_failed },
                 { type: :turn_canceled, cancellation_reason: :user }].sample(random: rng)
    end

    it "equal the sums over every record after each event, across a reload" do
      rng = Random.new(20_261_003)
      state_dir = Dir.mktmpdir
      metrics = frozen_metrics.tap { |m| m.state_dir = state_dir }
      30.times do |n|
        if n == 15
          metrics.persist
          metrics = frozen_metrics.tap { |m| m.state_dir = state_dir }
          metrics.session_id = "random"
          expect(totals(metrics.snapshot)).to eq(recomputed(metrics))
        end
        random_events(rng, "t#{n}").each do |event|
          metrics.call(event)
          snapshot = metrics.snapshot
          expect(totals(snapshot)).to eq(recomputed(metrics)), "turn #{n}, after #{event[:type]}"
          sums = segment_sums(snapshot)
          expect(sums).to eq(expected_sums(snapshot)), "segments, turn #{n}, after #{event[:type]}" if sums
        end
        metrics.persist if n.even?
      end
      expect(metrics.snapshot[:turns]).to eq(30)
      expect(metrics.snapshot[:model_segments].size).to eq(described_class::ModelSegment::CAP)
    end

    it "add up per model in a running turn's checkpoint (persist(running_turn: true))" do
      rng = Random.new(20_261_017)
      state_dir = Dir.mktmpdir
      metrics = frozen_metrics.tap { |m| m.state_dir = state_dir }
      12.times do |n|
        events = random_events(rng, "t#{n}")
        events.each { |event| metrics.call(event) }
      end
      random_events(rng, "running")[0...-1].each { |event| metrics.call(event) }
      metrics.persist(running_turn: true)

      saved = JSON.parse(File.read(Samagotchi::AnalyticsFile.path(Samagotchi::Session.session_dir("random", state_dir: state_dir))),
                         symbolize_names: true)
      expect(saved[:model_segments]).not_to be_empty
      expect(segment_sums(saved)).to eq(expected_sums(saved))
    end
  end

  # Side requests (a recap, a plugin's ctx.ask_model such as /btw) are a
  # separate side block: never in the turns' tokens or model_segments.
  describe "side requests (add_side and the side block)" do
    let(:price) { Samagotchi::ModelPrice.new(input: 2.0, cache_read: 0.5, cache_write: 4.0, output: 10.0) }
    let(:state_dir) { Dir.mktmpdir }

    def side(kind, prompt: 1000, completion: 20, cost: nil, price: nil, cached: 0, reasoning: 0)
      Samagotchi::SideUsage.new(kind: kind, model: "m", prompt_tokens: prompt, completion_tokens: completion,
                                cached_tokens: cached, cache_write_tokens: 0, reasoning_tokens: reasoning, cost: cost, price: price)
    end

    def turn(id)
      metrics.call(type: :turn_started, session_id: "side-sess", prompt: "p", turn_id: id)
      metrics.call(type: :generation_started, iteration: 1)
      metrics.call(type: :generation_chunk, iteration: 1, content: "x",
                   payload: { "choices" => [], "usage" => { "prompt_tokens" => 500, "completion_tokens" => 30, "cost" => 0.01 } })
      metrics.call(type: :generation_completed, iteration: 1)
      metrics.call(type: :turn_completed)
    end

    it "has no side key before any side request" do
      turn("t1")
      expect(metrics.snapshot).not_to have_key(:side)
    end

    it "sums a reported cost into cost_sum, with no estimate" do
      block = metrics.add_side(side("btw", cost: 0.0012, price: price))

      expect(block).to include(requests: 1, prompt_sum: 1000, completion_sum: 20, cost_sum: 0.0012, cost_estimate_sum: 0)
      expect(metrics.snapshot[:side]).to eq(block)
    end

    it "estimates from the price when no cost is reported (the shared rule), cost_sum staying nil" do
      metrics.add_side(side("recap", prompt: 1000, cached: 400, completion: 50, price: price))

      expected = Samagotchi::ModelPrice.estimate(price, reported_cost: nil, prompt_tokens: 1000, cached_tokens: 400,
                                                        cache_write_tokens: 0, completion_tokens: 50)
      expect(metrics.snapshot[:side]).to include(cost_sum: nil, cached_sum: 400)
      expect(metrics.snapshot[:side][:cost_estimate_sum]).to be_within(1e-12).of(expected)
    end

    it "counts by kind in first-seen order" do
      metrics.add_side(side("recap"))
      metrics.add_side(side("btw", cost: 0.5))
      metrics.add_side(side("recap", reasoning: 7))

      block = metrics.snapshot[:side]
      expect(block).to include(requests: 3, prompt_sum: 3000, completion_sum: 60, reasoning_sum: 7, cost_sum: 0.5)
      expect(block[:by_kind].keys).to eq(%w[recap btw])
      expect(block[:by_kind]["recap"]).to eq(requests: 2, cost_sum: nil, cost_estimate_sum: 0)
      expect(block[:by_kind]["btw"]).to eq(requests: 1, cost_sum: 0.5, cost_estimate_sum: 0)
    end

    it "leaves the tokens block and model_segments exactly as the turns alone made them" do
      # Both on the same frozen clock (see frozen_metrics): gen_ms is timed.
      metrics = frozen_metrics
      other = frozen_metrics
      [metrics, other].each do |collector|
        collector.call(type: :turn_started, session_id: "side-sess", prompt: "p", turn_id: "t1")
        collector.call(type: :generation_started, iteration: 1, model_ref: "a:m")
        collector.call(type: :generation_chunk, iteration: 1, content: "x",
                       payload: { "choices" => [], "usage" => { "prompt_tokens" => 500, "completion_tokens" => 30 } })
        collector.call(type: :generation_completed, iteration: 1)
        collector.call(type: :turn_completed)
      end
      metrics.add_side(side("btw", cost: 0.3, price: price))
      metrics.add_side(side("recap", price: price))

      expect(metrics.snapshot[:tokens]).to eq(other.snapshot[:tokens])
      expect(metrics.snapshot[:model_segments]).to eq(other.snapshot[:model_segments])
      expect(metrics.snapshot[:turn_records].map { |r| r.except(:started_at, :completed_at, :duration_ms) })
        .to eq(other.snapshot[:turn_records].map { |r| r.except(:started_at, :completed_at, :duration_ms) })
    end

    it "is saved to analytics.json and loaded by a new collector for the session" do
      metrics.state_dir = state_dir
      turn("t1")
      metrics.add_side(side("recap", price: price))
      metrics.add_side(side("btw", cost: 0.25))
      metrics.persist

      saved = JSON.parse(File.read(File.join(state_dir, "side-sess", "analytics.json")))
      expect(saved["side"]).to include("requests" => 2, "cost_sum" => 0.25)
      expect(saved["side"]["by_kind"].keys).to eq(%w[recap btw])

      woken = frozen_metrics.tap { |m| m.state_dir = state_dir }
      woken.session_id = "side-sess"
      expect(woken.snapshot[:side]).to eq(metrics.snapshot[:side])
      expect(woken.snapshot[:tokens]).to eq(metrics.snapshot[:tokens])
    end

    it "loads an analytics.json without a side block as before (no side key)" do
      metrics.state_dir = state_dir
      turn("t1")
      metrics.persist
      woken = frozen_metrics.tap { |m| m.state_dir = state_dir }
      woken.session_id = "side-sess"

      expect(woken.snapshot).not_to have_key(:side)
      expect(woken.snapshot[:tokens]).to eq(metrics.snapshot[:tokens])
    end

    it "keeps a side request counted before the session id is set, merged with the saved ones" do
      metrics.state_dir = state_dir
      metrics.session_id = "side-sess"
      metrics.add_side(side("recap"))
      metrics.persist

      woken = frozen_metrics.tap { |m| m.state_dir = state_dir }
      woken.add_side(side("btw", cost: 0.1))
      woken.session_id = "side-sess"

      expect(woken.snapshot[:side]).to include(requests: 2, cost_sum: 0.1)
      expect(woken.snapshot[:side][:by_kind].keys).to eq(%w[recap btw])
    end

    it "is SavedSummary#side (the saved hash), never in SavedSummary#tokens" do
      metrics.state_dir = state_dir
      turn("t1")
      metrics.add_side(side("btw", cost: 0.25))
      metrics.persist

      summary = described_class.saved_summary(Samagotchi::Session.session_dir("side-sess", state_dir: state_dir))
      expect(summary.side).to include("requests" => 1, "cost_sum" => 0.25, "by_kind" => { "btw" => include("requests" => 1) })
      expect(summary.tokens).not_to have_key(:side)
    end
  end

  describe Samagotchi::SessionMetrics::SideTotals do
    it "reads a saved block leniently: a non-Hash is zero, junk counts 0, a null cost_sum stays nil" do
      expect(described_class.from_saved(nil)).to eq(described_class.zero)
      expect(described_class.from_saved("x")).to be_empty
      loaded = described_class.from_saved("requests" => 2, "prompt_sum" => "lots", "cost_sum" => nil,
                                          "cost_estimate_sum" => 0.5, "by_kind" => { "recap" => { "requests" => 2 } })
      expect(loaded.to_h).to include(requests: 2, prompt_sum: 0, cost_sum: nil, cost_estimate_sum: 0.5)
      expect(loaded.by_kind).to eq("recap" => { requests: 2, cost_sum: nil, cost_estimate_sum: 0 })
    end

    it "counts a request whose usage reported no counts (Usage.none) as one with zero tokens" do
      usage = Samagotchi::SideUsage.from_usage(Samagotchi::LLM::Usage.none, kind: "recap", model: "m", price: nil)
      totals = described_class.zero.add(usage)

      expect(totals.to_h).to include(requests: 1, prompt_sum: 0, completion_sum: 0, cost_sum: nil, cost_estimate_sum: 0)
    end
  end

  it "is error-isolated and never raises on bad input" do
    expect { metrics.call(nil) }.not_to raise_error
    expect { metrics.call("not a hash") }.not_to raise_error
    expect { metrics.call({ type: :unknown_event }) }.not_to raise_error
  end
end

RSpec.describe Samagotchi::TokenUsage do
  describe "SessionMetrics.saved_summary" do
    let(:dir) { Dir.mktmpdir }

    def save(data) = File.write(File.join(dir, "analytics.json"), JSON.generate(data))

    it "reads the context's fill and the token totals in one go" do
      save("context" => { "used_tokens" => 250, "window_tokens" => 1000 },
           "tokens" => { "prompt_sum" => 900, "completion_sum" => 80, "cached_sum" => 600, "reasoning_sum" => 20,
                         "cost_sum" => 0.42 })
      summary = Samagotchi::SessionMetrics.saved_summary(dir)
      expect(summary.ctx_pct).to eq(25.0)
      expect(summary.tokens).to eq(prompt_sum: 900, completion_sum: 80, cached_sum: 600, reasoning_sum: 20, cost_sum: 0.42,
                                   cost_estimate_sum: 0)
    end

    it "has zeros for the counts an older file lacks, and is nil without a file" do
      expect(Samagotchi::SessionMetrics.saved_summary(dir)).to be_nil
      save("tokens" => { "prompt_sum" => 9, "completion_sum" => 1, "source" => "server" })
      expect(Samagotchi::SessionMetrics.saved_summary(dir))
        .to have_attributes(ctx_pct: nil, cached_sum: 0, cost_sum: 0, cost_estimate_sum: 0, memory_index: nil)
    end

    it "reads the memory indexes the prompt held, apart from the token totals" do
      index = { "system" => { "tokens" => 1997, "lines" => 54 }, "project" => { "tokens" => 1394, "lines" => 35 } }
      save("tokens" => { "prompt_sum" => 9 }, "memory_index" => index)
      summary = Samagotchi::SessionMetrics.saved_summary(dir)
      expect(summary.memory_index).to eq(index)
      expect(summary.tokens).not_to have_key(:memory_index)
    end
  end

  describe "SessionMetrics.saved_context_pct" do
    let(:dir) { Dir.mktmpdir }

    def save(data) = File.write(File.join(dir, "analytics.json"), JSON.generate(data))

    it "reads the saved context's fill" do
      save("context" => { "used_tokens" => 250, "window_tokens" => 1000 })
      expect(Samagotchi::SessionMetrics.saved_context_pct(dir)).to eq(25.0)
    end

    it "is nil without a file, a context, either count, or with a broken file" do
      expect(Samagotchi::SessionMetrics.saved_context_pct(dir)).to be_nil
      save("turns" => 3)
      expect(Samagotchi::SessionMetrics.saved_context_pct(dir)).to be_nil
      save("context" => { "used_tokens" => 250, "window_tokens" => nil })
      expect(Samagotchi::SessionMetrics.saved_context_pct(dir)).to be_nil
      File.write(File.join(dir, "analytics.json"), "{")
      expect(Samagotchi::SessionMetrics.saved_context_pct(dir)).to be_nil
    end

    it "counts against the llm_context budget when it is smaller than the window, as the live meter does" do
      save("context" => { "used_tokens" => 2500, "window_tokens" => 10_000 })
      expect(Samagotchi::SessionMetrics.saved_context_pct(dir, budget_tokens: 4000)).to eq(62.5)
      expect(Samagotchi::SessionMetrics.saved_summary(dir, budget_tokens: 4000).ctx_pct).to eq(62.5)
    end

    it "keeps the window for a budget larger than it, nil and 0" do
      save("context" => { "used_tokens" => 2500, "window_tokens" => 10_000 })

      [60_000, nil, 0].each do |budget|
        pct = Samagotchi::SessionMetrics.saved_context_pct(dir, budget_tokens: budget)
        expect(pct).to eq(25.0), "budget #{budget.inspect}"
      end
    end

    it "resolves a budget a caller passes as a callable only when there is a context to count" do
      calls = 0
      budget = -> { calls += 1; 4000 }

      save("turns" => 3)
      expect(Samagotchi::SessionMetrics.saved_context_pct(dir, budget_tokens: budget)).to be_nil
      expect(calls).to eq(0)

      save("context" => { "used_tokens" => 2500, "window_tokens" => 10_000 })
      expect(Samagotchi::SessionMetrics.saved_context_pct(dir, budget_tokens: budget)).to eq(62.5)
      expect(calls).to eq(1)
    end
  end

  describe "SessionMetrics.saved_tool_records" do
    let(:dir) { Dir.mktmpdir }

    def save(data) = File.write(File.join(dir, "analytics.json"), JSON.generate(data))

    it "reads one turn's saved tool records in call order" do
      save("tool_records" => [
        { "turn_id" => "t1", "iteration" => 2, "call_index" => 1, "tool" => "read", "duration_ms" => 30 },
        { "turn_id" => "t0", "iteration" => 1, "call_index" => 1, "tool" => "read", "duration_ms" => 99 },
        { "turn_id" => "t1", "iteration" => 1, "call_index" => 2, "tool" => "grep", "duration_ms" => 20 },
        { "turn_id" => "t1", "iteration" => 1, "call_index" => 1, "tool" => "execute", "duration_ms" => 10 }
      ])
      records = Samagotchi::SessionMetrics.saved_tool_records(dir, "t1")
      expect(records.map { |r| [r["tool"], r["duration_ms"]] }).to eq([["execute", 10], ["grep", 20], ["read", 30]])
    end

    it "is empty without a turn id, a file, records, or with a broken file" do
      expect(Samagotchi::SessionMetrics.saved_tool_records(dir, "t1")).to eq([])
      save("tool_records" => [{ "turn_id" => "t1", "tool" => "read", "duration_ms" => 1 }])
      expect(Samagotchi::SessionMetrics.saved_tool_records(dir, nil)).to eq([])
      save("turns" => 3)
      expect(Samagotchi::SessionMetrics.saved_tool_records(dir, "t1")).to eq([])
      File.write(File.join(dir, "analytics.json"), "{")
      expect(Samagotchi::SessionMetrics.saved_tool_records(dir, "t1")).to eq([])
    end
  end

  describe "SessionMetrics.saved_turn_record" do
    let(:dir) { Dir.mktmpdir }

    def save(data) = File.write(File.join(dir, "analytics.json"), JSON.generate(data))

    it "reads the saved record whose id is the turn id" do
      save("turn_records" => [
        { "id" => "t0", "status" => "completed" },
        { "id" => "t1", "status" => "failed", "failure" => { "summary" => "boom" } }
      ])

      expect(Samagotchi::SessionMetrics.saved_turn_record(dir, "t1"))
        .to eq({ "id" => "t1", "status" => "failed", "failure" => { "summary" => "boom" } })
    end

    it "is nil without a turn id, a matching record, a file, or with a broken file" do
      expect(Samagotchi::SessionMetrics.saved_turn_record(dir, "t1")).to be_nil
      save("turn_records" => [{ "id" => "t1", "status" => "completed" }])
      expect(Samagotchi::SessionMetrics.saved_turn_record(dir, nil)).to be_nil
      expect(Samagotchi::SessionMetrics.saved_turn_record(dir, "t9")).to be_nil
      save("turns" => 3)
      expect(Samagotchi::SessionMetrics.saved_turn_record(dir, "t1")).to be_nil
      File.write(File.join(dir, "analytics.json"), "{")
      expect(Samagotchi::SessionMetrics.saved_turn_record(dir, "t1")).to be_nil
    end
  end

  describe ".from_payload" do
    it "extracts llama.cpp timings" do
      result = described_class.from_payload("timings" => { "prompt_n" => 50, "predicted_n" => 12 })
      expect(result).to have_attributes(prompt_tokens: 50, completion_tokens: 12, source: :server)
    end

    it "extracts mlx usage" do
      result = described_class.from_payload("usage" => { "prompt_tokens" => 7, "completion_tokens" => 3 })
      expect(result).to have_attributes(prompt_tokens: 7, completion_tokens: 3, cached_tokens: nil, cost: nil,
                                        predicted_per_second: nil, source: :server)
    end

    it "returns nil when no token data is present" do
      expect(described_class.from_payload("content" => "hi")).to be_nil
      expect(described_class.from_payload(nil)).to be_nil
    end

    it "accepts float token counts without raising" do
      # Some backends emit floats (e.g. 50.0); ensure it coerces instead of
      # raising RangeError.
      result = described_class.from_payload("timings" => { "prompt_n" => 50.0, "predicted_n" => 12.9 })
      expect(result).to have_attributes(prompt_tokens: 50, completion_tokens: 12, source: :server)
    end
  end

  describe ".estimate" do
    it "uses the chars/4 heuristic" do
      expect(described_class.estimate("hello world")).to eq(3)
    end

    it "returns 0 for empty/non-string input" do
      expect(described_class.estimate("")).to eq(0)
      expect(described_class.estimate(nil)).to eq(0)
    end
  end
end
