# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_metrics"
require "samagotchi/token_usage"

RSpec.describe Samagotchi::SessionMetrics do
  let(:metrics) { described_class.new }

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

      woken = described_class.new
      woken.state_dir = state_dir
      woken.session_id = "ctx-sess"

      expect(woken.snapshot[:context]).to include(used_tokens: 350, window_tokens: 4096, window_source: "server")
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
        context_used_tokens: 150, token_source: "server", tool_calls: 1, tool_errors: 1, iterations: 1, retries: 0
      )
      expect(metrics.snapshot[:turn_records].last[:gen_ms]).to be_a(Integer)
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

    it "starts the clock on a tool call delta too" do
      start_turn
      metrics.call(type: :generation_started, iteration: 1)
      tick(1.0)
      metrics.call(type: :generation_chunk, iteration: 1, content: "",
                   payload: { "choices" => [{ "delta" => { "tool_calls" => [{ "index" => 0 }] } }] })
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

      woken = described_class.new.tap { |m| m.state_dir = dir }
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
    expect(metrics.persist(state_dir: state_dir)).to eq(true)
    dir = Samagotchi::Session.session_dir("persist-sess", state_dir: state_dir)
    expect(File.exist?(File.join(dir, "analytics.json"))).to be(true)
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
    metrics = described_class.new
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

  it "keeps the earlier records in its state dir when a later worker persists analytics" do
    state_dir = Dir.mktmpdir
    first = described_class.new
    first.state_dir = state_dir
    first.call(type: :turn_started, session_id: "resumed", prompt: "one")
    first.call(type: :turn_completed, result: double(respond_to?: false))
    first.persist

    second = described_class.new
    second.state_dir = state_dir
    second.call(type: :turn_started, session_id: "resumed", prompt: "two")
    second.call(type: :turn_completed, result: double(respond_to?: false))
    second.persist

    path = File.join(Samagotchi::Session.session_dir("resumed", state_dir: state_dir), "analytics.json")
    expect(JSON.parse(File.read(path)).fetch("turn_records").size).to eq(2)
  end

  it "brings back the served model a woken collector's session last reported" do
    state_dir = Dir.mktmpdir
    first = described_class.new
    first.state_dir = state_dir
    first.call(type: :turn_started, session_id: "woken", prompt: "one")
    first.call(type: :generation_started, iteration: 1)
    first.call(type: :generation_completed, iteration: 1, served_model: "ornith", requested_model: "qwen")
    first.call(type: :turn_completed)
    first.persist

    woken = described_class.new
    woken.state_dir = state_dir
    woken.session_id = "woken"

    expect(woken.served_report).to eq(served_model: "ornith", served_model_for: "qwen")
    expect(woken.snapshot).to include(served_model: "ornith", served_model_for: "qwen")
  end

  it "saves a call still running when its turn ends as canceled, so the records match the count" do
    state_dir = Dir.mktmpdir
    metrics = described_class.new
    metrics.state_dir = state_dir
    metrics.call(type: :turn_started, session_id: "cut", prompt: "x")
    metrics.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "read")
    metrics.call(type: :tool_call_completed, iteration: 1, call_index: 1, tool: "read", status: "ok")
    metrics.call(type: :tool_call_started, iteration: 1, call_index: 2, tool: "execute")
    metrics.call(type: :turn_canceled, cancellation_reason: :user)

    snap = metrics.snapshot
    expect(snap[:tool_records].map { |r| [r[:tool], r[:status]] }).to eq([%w[read ok], %w[execute canceled]])
    expect(snap[:tool_calls_total]).to eq(2)
    expect(snap[:tool_calls_by_tool]).to eq("read" => 1, "execute" => 1)
    expect(snap[:turn_records].last[:tool_calls]).to eq(snap[:tool_records].size)
    expect(snap[:active_tools]).to be_empty
    metrics.persist

    woken = described_class.new
    woken.state_dir = state_dir
    woken.session_id = "cut"
    expect(woken.snapshot).to include(tool_calls_total: 2, tool_calls_by_tool: { "read" => 1, "execute" => 1 })
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

    turn.call(described_class.new, 100, "read")
    second = described_class.new
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
    let(:metrics) { described_class.new.tap { |m| m.state_dir = state_dir } }

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
      blocked = described_class.new.tap { |m| m.state_dir = File.join(state_dir, "file") }
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
      bare = described_class.new
      (1..22).each { |n| run_turn(bare, n, tools: 0, sid: nil) }
      expect(bare.persist).to be(false)
      expect(bare.snapshot[:turn_records].size).to eq(20)
      expect(bare.snapshot[:turns]).to eq(22)
    end

    it "a woken collector has no records but every turn in its totals, and saves them all" do
      first = described_class.new.tap { |m| m.state_dir = state_dir }
      (1..5).each do |n|
        run_turn(first, n)
        first.persist
      end
      first.call(type: :turn_started, session_id: "live", prompt: "p6", turn_id: "t6")
      first.call(type: :generation_retrying, attempt: 1)
      first.call(type: :turn_canceled, cancellation_reason: :user)
      first.persist

      woken = described_class.new.tap { |m| m.state_dir = state_dir }
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

    def random_events(rng, turn_id)
      events = [{ type: :turn_started, session_id: "random", prompt: "p", turn_id: turn_id }]
      rng.rand(0..3).times do |iteration|
        events << { type: :generation_started, iteration: iteration + 1 }
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
      metrics = described_class.new.tap { |m| m.state_dir = state_dir }
      30.times do |n|
        if n == 15
          metrics.persist
          metrics = described_class.new.tap { |m| m.state_dir = state_dir }
          metrics.session_id = "random"
          expect(totals(metrics.snapshot)).to eq(recomputed(metrics))
        end
        random_events(rng, "t#{n}").each do |event|
          metrics.call(event)
          expect(totals(metrics.snapshot)).to eq(recomputed(metrics)), "turn #{n}, after #{event[:type]}"
        end
        metrics.persist if n.even?
      end
      expect(metrics.snapshot[:turns]).to eq(30)
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
      expect(summary.tokens).to eq(prompt_sum: 900, completion_sum: 80, cached_sum: 600, reasoning_sum: 20, cost_sum: 0.42)
    end

    it "has zeros for the counts an older file lacks, and is nil without a file" do
      expect(Samagotchi::SessionMetrics.saved_summary(dir)).to be_nil
      save("tokens" => { "prompt_sum" => 9, "completion_sum" => 1, "source" => "server" })
      expect(Samagotchi::SessionMetrics.saved_summary(dir)).to have_attributes(ctx_pct: nil, cached_sum: 0, cost_sum: 0)
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
