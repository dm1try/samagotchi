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

  it "starts empty" do
    snap = metrics.snapshot
    expect(snap[:turns]).to eq(0)
    expect(snap[:tokens]).to eq(prompt_sum: 0, completion_sum: 0, source: nil)
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
    expect(snap[:tokens]).to eq(prompt_sum: 120, completion_sum: 30, source: "server")
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
    expect(snap[:tokens]).to eq(prompt_sum: 0, completion_sum: 3, source: "estimate")
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
    expect(snap[:tokens]).to eq(prompt_sum: 250, completion_sum: 35, source: "server")
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
    expect(written["tokens"]).to eq("prompt_sum" => 250, "completion_sum" => 20, "source" => "server")
    expect(second.snapshot).to include(turns: 2, tool_calls_total: 2)
  ensure
    ENV["XDG_STATE_HOME"] = original
  end

  it "is error-isolated and never raises on bad input" do
    expect { metrics.call(nil) }.not_to raise_error
    expect { metrics.call("not a hash") }.not_to raise_error
    expect { metrics.call({ type: :unknown_event }) }.not_to raise_error
  end
end

RSpec.describe Samagotchi::TokenUsage do
  describe ".from_payload" do
    it "extracts llama.cpp timings" do
      result = described_class.from_payload("timings" => { "prompt_n" => 50, "predicted_n" => 12 })
      expect(result).to eq(prompt_tokens: 50, completion_tokens: 12, source: :server)
    end

    it "extracts mlx usage" do
      result = described_class.from_payload("usage" => { "prompt_tokens" => 7, "completion_tokens" => 3 })
      expect(result).to eq(prompt_tokens: 7, completion_tokens: 3, source: :server)
    end

    it "returns nil when no token data is present" do
      expect(described_class.from_payload("content" => "hi")).to be_nil
      expect(described_class.from_payload(nil)).to be_nil
    end

    it "accepts float token counts without raising" do
      # Some backends emit floats (e.g. 50.0); ensure it coerces instead of
      # raising RangeError.
      result = described_class.from_payload("timings" => { "prompt_n" => 50.0, "predicted_n" => 12.9 })
      expect(result).to eq(prompt_tokens: 50, completion_tokens: 12, source: :server)
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
