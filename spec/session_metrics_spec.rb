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
    expect(snap[:tokens_in]).to eq(0)
    expect(snap[:tokens_out]).to eq(0)
    expect(snap[:tool_calls_total]).to eq(0)
    expect(snap[:token_source]).to be_nil
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
    expect(snap[:tokens_in]).to eq(120)
    expect(snap[:tokens_out]).to eq(30)
    expect(snap[:tokens_total]).to eq(150)
    expect(snap[:token_source]).to eq(:server)
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

  it "keeps the latest context window :generation_started reported" do
    expect(metrics.snapshot).to include(context_window_tokens: nil, context_window_source: nil)

    feed([
      { type: :turn_started, session_id: "sess-1", prompt: "hi" },
      { type: :generation_started, iteration: 1, context_window_tokens: 256_000, context_window_source: :default },
      { type: :generation_started, iteration: 2, context_window_tokens: 128_000, context_window_source: :server },
      { type: :generation_started, iteration: 3 }
    ])

    expect(metrics.snapshot).to include(context_window_tokens: 128_000, context_window_source: :server)
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
    expect(snap[:token_source]).to eq(:estimate)
    # 11 chars / 4.0 -> ceil -> 3
    expect(snap[:tokens_out]).to eq(3)
    expect(snap[:tokens_total]).to eq(snap[:tokens_out])
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
    expect(snap[:tokens_in]).to eq(150) # running max of the growing prompt
    expect(snap[:tokens_out]).to eq(35) # 10 + 25 summed across generations
    expect(snap[:tokens_total]).to eq(185)
    expect(snap[:token_source]).to eq(:server)
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
    expect(snap[:token_source]).to eq(:server)
    expect(snap[:tokens_out]).to eq(7)
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
    expect(snap[:tokens_in]).to eq(20)
    expect(snap[:tokens_out]).to eq(4)
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

    expect(metrics.snapshot[:tokens_out]).to eq(5)
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

  it "merges completed timing records when a later worker persists analytics" do
    state_dir = Dir.mktmpdir
    first = described_class.new
    first.call(type: :turn_started, session_id: "resumed", prompt: "one")
    first.call(type: :turn_completed, result: double(respond_to?: false))
    first.persist(state_dir: state_dir)

    second = described_class.new
    second.call(type: :turn_started, session_id: "resumed", prompt: "two")
    second.call(type: :turn_completed, result: double(respond_to?: false))
    second.persist(state_dir: state_dir)

    path = File.join(Samagotchi::Session.session_dir("resumed", state_dir: state_dir), "analytics.json")
    expect(JSON.parse(File.read(path)).fetch("turn_records").size).to eq(2)
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
