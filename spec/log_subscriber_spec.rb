# frozen_string_literal: true

require "samagotchi/log_subscriber"
require "samagotchi/engine"
require "samagotchi/session"
require "fileutils"
require "tmpdir"

RSpec.describe Samagotchi::LogSubscriber do
  let(:dir) { Dir.mktmpdir("samagotchi-log") }
  let(:path) { File.join(dir, "chi.log") }
  let(:now) { [100.0] }
  let(:subscriber) { described_class.new(session_id: -> { "0123456789abcdef" }, clock: -> { now.first }) }

  before { Samagotchi::Log.configure(path: path) }
  after { FileUtils.remove_entry(dir) if File.directory?(dir) }

  def records
    return [] unless File.exist?(path)

    File.open(path) { |io| Samagotchi::LogLine.each_record(io).to_a }
  end

  def feed(*events)
    events.each { |event| subscriber.call(event) }
  end

  it "logs a merge's steers by count and source, never their text" do
    feed({ type: :pending_input_merged, iteration: 3, count: 1, content: "user text",
           steers: [{ source: "check-in", text: "secret nudge" }] },
         { type: :pending_input_merged, iteration: 4, count: 1, content: "more" })

    expect(records.map { |r| r.fields }).to eq([
      { "iteration" => "3", "count" => "1", "steers" => "1", "steer_sources" => "check-in" },
      { "iteration" => "4", "count" => "1" }
    ])
    expect(File.read(path)).not_to include("secret nudge", "user text")
  end

  it "writes a turn with its generations and tools, timed by pairing starts and ends" do
    feed({ type: :turn_started, session_id: "0123456789abcdef", prompt: "secret prompt", origin: { client_id: "web:tab1" } },
         { type: :generation_started, iteration: 1, profile: "qwen36" })
    now[0] = 101.5
    feed({ type: :generation_chunk, iteration: 1, text: "x" },
         { type: :generation_completed, iteration: 1, served_model: "Qwen3.6", requested_model: "qwen", content_length: 42,
           thinking_chars: 900 },
         { type: :tool_call_started, iteration: 1, call_index: 0, tool: "read" })
    now[0] = 101.75
    feed({ type: :tool_call_completed, iteration: 1, call_index: 0, tool: "read", output: "[read]\nfile body", output_truncated: false })
    now[0] = 103.0
    feed({ type: :turn_completed, turn_summary: { output: "the answer", tool_activity: [{}] } })

    expect(records.map { |r| [r.level, r.tag, r.sid, r.event, r.fields] }).to eq([
      ["INFO", "turn", "01234567", "turn_started", { "session" => "0123456789abcdef", "prompt_chars" => "13", "client_id" => "web:tab1" }],
      ["INFO", "turn", "01234567", "generation_completed",
       { "iteration" => "1", "ms" => "1500", "served_model" => "Qwen3.6", "requested_model" => "qwen", "content_length" => "42",
         "thinking_chars" => "900" }],
      ["INFO", "turn", "01234567", "tool_call_completed", { "iteration" => "1", "tool" => "read", "ms" => "250", "output_chars" => "16" }],
      ["INFO", "turn", "01234567", "turn_completed", { "ms" => "3000", "result_chars" => "10", "tools" => "1" }]
    ])
    expect(File.read(path)).not_to include("secret prompt", "the answer", "file body")
  end

  it "writes an empty-answer retry and a generation's finish reason" do
    feed({ type: :generation_started, iteration: 1 },
         { type: :generation_completed, iteration: 1, content_length: 0, thinking_chars: 240_000, finish_reason: "length" },
         { type: :empty_answer_retry, iteration: 1, attempt: 1, of: 1, finish_reason: "length", thinking_chars: 240_000 })

    expect(records.map { |r| [r.event, r.fields.slice("finish_reason", "attempt", "of", "thinking_chars")] }).to eq([
      ["generation_completed", { "finish_reason" => "length", "thinking_chars" => "240000" }],
      ["empty_answer_retry", { "finish_reason" => "length", "attempt" => "1", "of" => "1", "thinking_chars" => "240000" }]
    ])
  end

  it "logs generation_started at debug only" do
    Samagotchi::Log.configure(path: path, level: :debug)
    feed({ type: :generation_started, iteration: 2, profile: "gemma4", context_window_tokens: 8192 })

    expect(records.first.to_h).to include(level: "DEBUG", event: "generation_started",
                                          fields: { "iteration" => "2", "profile" => "gemma4", "context_window" => "8192" })
  end

  it "marks a failed tool call" do
    feed({ type: :tool_call_completed, iteration: 1, call_index: 0, tool: "read", output: "[read] Error: no such file" },
         { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "read", output: "[read]\nError: denied" },
         { type: :tool_call_completed, iteration: 1, call_index: 2, tool: "nope", output: "Error: unknown tool 'nope'" },
         { type: :tool_call_completed, iteration: 1, call_index: 3, tool: "read", output: "[read]\nno Error: here" })

    expect(records.map { |r| r.fields["error"] }).to eq(["true", "true", "true", nil])
  end

  it "writes retries and failures as warnings, with the provider's kind and host" do
    feed({ type: :generation_retrying, iteration: 1, attempt: 1, max_retries: 3, next_delay: 2.0,
           error_class: "Samagotchi::LLM::ProviderError", error_message: "429 Too Many Requests" },
         { type: :turn_failed, error_class: "Samagotchi::LLM::ProviderError", message: "long", error_kind: :rate_limited,
           retryable: true, host: "openrouter", summary: "openrouter: rate limited (429)" })

    expect(records.map { |r| [r.level, r.event, r.fields] }).to eq([
      ["WARN", "generation_retrying", { "iteration" => "1", "attempt" => "1", "max_retries" => "3", "delay_s" => "2.0",
                                        "error" => "Samagotchi::LLM::ProviderError", "msg" => "429 Too Many Requests" }],
      ["WARN", "turn_failed", { "error" => "Samagotchi::LLM::ProviderError", "error_kind" => "rate_limited",
                                "host" => "openrouter", "retryable" => "true", "msg" => "openrouter: rate limited (429)" }]
    ])
  end

  it "writes announced events with their ids, not their text, and skips the noisy ones" do
    feed({ type: :turn_enqueued, enqueued_id: "e1", client_id: "tui:1", prompt: "queued text" },
         { type: :command_ran, command_id: "c1", client_id: "web:1", status: :ok, output: "long output", line: "/stats" },
         { type: :recap_ready, recap: "a recap", generation: 3, covered: 12 },
         { type: :guardrail_warning, message: "rules failed to load" },
         { type: :context_status, status: "x" }, { type: :used_memories_updated }, { type: :tool_dispatch_started })

    expect(records.map { |r| [r.event, r.fields] }).to eq([
      ["turn_enqueued", { "enqueued_id" => "e1", "client_id" => "tui:1" }],
      ["command_ran", { "command_id" => "c1", "client_id" => "web:1", "status" => "ok" }],
      ["recap_ready", { "chars" => "7", "generation" => "3", "covered" => "12" }],
      ["guardrail_warning", { "msg" => "rules failed to load" }]
    ])
    expect(File.read(path)).not_to include("queued text", "long output", "a recap")
  end

  it "writes a hook's notice with its label, at the notice's level" do
    feed({ type: :hook_notice, hook: "known_names.rb (bundle known-names)", text: "rejected execute: x", level: :info },
         { type: :hook_notice, hook: "turn hook", text: "stopped the turn: y", level: :warn })

    expect(records.map { |r| [r.level, r.event, r.fields] }).to eq([
      ["INFO", "hook_notice", { "hook" => "known_names.rb (bundle known-names)", "msg" => "rejected execute: x" }],
      ["WARN", "hook_notice", { "hook" => "turn hook", "msg" => "stopped the turn: y" }]
    ])
  end

  it "writes a card with its source, id and title, not its body" do
    feed({ type: :card, id: "c1", source: "sample-plugin", title: "Hello", body: "secret body", level: :info,
           actions: [{ label: "Again", command: "/hello again" }] })

    expect(records.map { |r| [r.event, r.fields] }).to eq([
      ["card", { "source" => "sample-plugin", "id" => "c1", "actions" => "1", "msg" => "Hello" }]
    ])
    expect(File.read(path)).not_to include("secret body")
  end

  it "writes a tool call whose output is invalid UTF-8 (any bytes a command printed)" do
    feed({ type: :tool_call_completed, iteration: 1, call_index: 0, tool: "execute",
           output: (+"[execute]\nbad \xFF\xFE bytes").force_encoding(Encoding::UTF_8) })

    expect(records.map { |r| [r.event, r.fields["output_chars"]] }).to eq([["tool_call_completed", "22"]])
  end

  it "never raises into the observer" do
    expect { subscriber.call({ type: :tool_call_completed, output: Object.new }) }.not_to raise_error
    expect { subscriber.call({}) }.not_to raise_error
  end

  describe "on an Engine" do
    around do |example|
      original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
      example.run
    ensure
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
    end

    it "is subscribed, so every run_turn leaves a trail with the session's sid" do
      client = instance_double(Samagotchi::Client)
      kernel = instance_double(Samagotchi::KernelLoop)
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(kernel).to receive(:run).and_return(
        Samagotchi::KernelLoop::Result.new(output: "done", conversation: [{ role: "model", content: "done" }], exhausted: false,
                                           pending_tool_calls: false, tool_activity: [], canceled: false)
      )
      engine = Samagotchi::Engine.new(mode: :assist, client: client, kernel: kernel, profile: "gemma4")
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)

      engine.run_turn(session, "hi")

      trail = records.select { |r| r.tag == "turn" }
      expect(trail.map(&:event)).to eq(%w[turn_started turn_completed])
      expect(trail.map(&:sid).uniq).to eq([session.id[0, 8]])
      expect(trail.first.fields["session"]).to eq(session.id)
    end
  end
end
