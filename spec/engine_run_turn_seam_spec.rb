# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "support/test_kernel"

# What Engine#run_turn has to offer before the interactive TUI can drive its
# turns through it (Phase R2 of the shared-session plan).
RSpec.describe Samagotchi::Engine, "#run_turn as the TUI seam" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:activity) { { action: "running command", tool: "execute", params: 'command="ls"', status: "ok" } }

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

  def kernel_result(**overrides)
    Samagotchi::LLM::ModelResult.new(
      text: "done", conversation: [{ role: "model", content: "done" }], exhausted: false,
      pending_tool_calls: false, tool_activity: [], canceled: false, **overrides
    )
  end

  def events_of(**kwargs)
    events = []
    engine.run_turn(session, kwargs.delete(:prompt) || "hi", on_event: ->(e) { events << e }, **kwargs)
    events
  end

  describe "turn_summary on :turn_completed" do
    it "carries the native loop's tool activity, context status and continuation flags" do
      context_status = { est_pct: 12.5, bucket: "low" }
      allow(kernel).to receive(:run).and_return(
        kernel_result(exhausted: true, pending_tool_calls: true, tool_activity: [activity], context_status: context_status)
      )

      completed = events_of.find { |e| e[:type] == :turn_completed }

      expect(completed[:result]).to be_a(Samagotchi::LLM::ModelResult)
      expect(completed[:turn_summary]).to eq(
        output: "done", exhausted: true, resumable: true, pending_tool_calls: true,
        tool_activity: [activity], context_status: context_status
      )
      expect(JSON.parse(JSON.generate(completed[:turn_summary]))).to include("resumable" => true)
    end

    it "keeps the last reported context status for a client that attaches later" do
      allow(kernel).to receive(:run).and_return(kernel_result(context_status: { est_pct: 7.5, bucket: "under20" }),
                                                kernel_result)

      expect(engine.session_state_snapshot[:context_status]).to be_nil
      engine.run_turn(session, "hi")
      engine.run_turn(session, "again")

      expect(engine.session_state_snapshot[:context_status]).to eq(est_pct: 7.5, bucket: "under20")
    end

    it "is also available on the returned result" do
      allow(kernel).to receive(:run).and_return(kernel_result(tool_activity: [activity]))

      result = engine.run_turn(session, "hi")

      expect(result.tool_activity).to eq([activity])
      expect(result.pending_tool_calls?).to be(false)
    end
  end

  describe "continue: true" do
    it "runs the existing conversation without appending a prompt" do
      session.messages = [{ role: "system", content: "old" }, { role: "user", content: "go" }, { role: "tool_response", content: "r" }]
      session.last_prompt = "go"
      sent = nil
      allow(kernel).to receive(:run) { |messages, **| sent = messages; kernel_result }

      events = events_of(prompt: "ignored", continue: true)

      expect(sent.drop(1)).to eq([{ role: "user", content: "go" }, { role: "tool_response", content: "r" }])
      expect(sent.first[:role]).to eq("system")
      expect(session.last_prompt).to eq("go")
      expect(events.first).to include(type: :turn_started, prompt: nil, continue: true)
    end

    it "keeps :turn_started unchanged for a normal turn" do
      allow(kernel).to receive(:run).and_return(kernel_result)

      expect(events_of.first).to match(type: :turn_started, session_id: session.id, prompt: "hi", turn_id: a_string_matching(/\A\h{8}-/))
    end
  end

  describe "turn id" do
    it "is on :turn_started and on the turn's saved prompt, so a UI pairs the prompt with its turn record" do
      sent = nil
      allow(kernel).to receive(:run) { |messages, **| sent = messages; kernel_result }

      started = events_of.first
      prompt = sent.find { |m| m[:role] == "user" }

      expect(started[:turn_id]).to match(/\A\h{8}-/)
      expect(prompt).to include(content: "hi", turn_id: started[:turn_id])
    end
  end

  describe "session status" do
    it "is running during the turn and idle by the time its end is announced" do
      seen = {}
      allow(kernel).to receive(:run) do
        seen[:during] = session.status
        kernel_result
      end
      engine.subscribe(observer: ->(e) { seen[e[:type]] = session.status if e[:type] == :turn_completed })

      engine.run_turn(session, "hi")

      expect(seen).to eq(during: "running", turn_completed: "idle")
      expect(engine.session_state_snapshot[:status]).to eq("idle")
    end

    it "goes back to idle after a cancel, a Ctrl-C and a failure" do
      allow(kernel).to receive(:run).and_return(kernel_result(canceled: true, cancellation_reason: :manual))
      engine.run_turn(session, "hi")
      expect(session.status).to eq("idle")

      allow(kernel).to receive(:run) { session.status.then { raise Interrupt } }
      expect { engine.run_turn(session, "hi") }.to raise_error(Interrupt)
      expect(session.status).to eq("idle")

      allow(kernel).to receive(:run).and_raise(RuntimeError, "boom")
      expect { engine.run_turn(session, "hi") }.to raise_error(RuntimeError)
      expect(session.status).to eq("idle")
    end
  end

  describe "last_turn" do
    it "says how the turn ended, how long it took and who asked, by the time its end is announced" do
      allow(kernel).to receive(:run).and_return(kernel_result)
      seen = nil
      engine.subscribe(observer: ->(e) { seen = session.last_turn if e[:type] == :turn_completed })

      engine.run_turn(session, "hi")

      expect(seen).to include("outcome" => "completed", "origin" => "client")
      expect(seen["seconds"]).to be_a(Float)
      expect(Time.iso8601(seen["ended_at"])).to be_within(5).of(Time.now)
    end

    it "records a cancel, a Ctrl-C and a failure" do
      allow(kernel).to receive(:run).and_return(kernel_result(canceled: true, cancellation_reason: :manual))
      engine.run_turn(session, "hi")
      expect(session.last_turn["outcome"]).to eq("canceled")

      allow(kernel).to receive(:run).and_raise(Interrupt)
      expect { engine.run_turn(session, "hi") }.to raise_error(Interrupt)
      expect(session.last_turn["outcome"]).to eq("canceled")

      allow(kernel).to receive(:run).and_raise(RuntimeError, "boom")
      expect { engine.run_turn(session, "hi") }.to raise_error(RuntimeError)
      expect(session.last_turn["outcome"]).to eq("failed")
    end

    it "maps the origin: a delegate, a reminder, a client, none" do
      allow(kernel).to receive(:run).and_return(kernel_result)
      {
        { client_id: "delegate:abcd1234" } => "delegate",
        { client_id: "system:reminder" } => "reminder",
        { client_id: "web:tab-1" } => "client",
        nil => "client"
      }.each do |origin, expected|
        engine.run_turn(session, "hi", origin: origin)
        expect(session.last_turn["origin"]).to eq(expected)
      end
    end
  end

  describe "when the turn's end is announced" do
    it "has the session's messages already updated, the note included" do
      allow(kernel).to receive(:run).and_return(
        kernel_result(text: "", conversation: [{ role: "user", content: "hi" }])
      )
      seen = nil
      engine.subscribe(observer: ->(e) { seen = session.messages.dup if e[:type] == :turn_completed })

      engine.run_turn(session, "hi")

      expect(seen.first(2)).to eq([{ role: "user", content: "hi" }, seen.last])
      expect(seen.last).to include(role: "system", kind: "turn_note")
      expect(seen.last[:content]).to include("no visible answer")
    end

    it "has the messages kept on a Ctrl-C" do
      allow(kernel).to receive(:run).and_raise(Interrupt)
      seen = nil
      engine.subscribe(observer: ->(e) { seen = session.messages.map { |m| m[:content] } if e[:type] == :turn_canceled })

      expect { engine.run_turn(session, "hi") }.to raise_error(Interrupt)

      expect(seen[-2]).to eq("hi")
      expect(seen.last).to include("cancelled (ctrl-c)")
    end
  end

  it "invalidates an in-flight recap when a turn starts, for every UI", :recap do
    engine = described_class.new(client: client, kernel: kernel, profile: "gemma4",
                                 recap: { base_url: "http://127.0.0.1:1", model: "m" })
    allow(engine.recap).to receive(:invalidate!).and_call_original
    allow(kernel).to receive(:run) do
      expect(engine.recap).to have_received(:invalidate!)
      kernel_result
    end

    engine.run_turn(session, "hi")
  end

  describe "origin:" do
    let(:origin) { { client_id: "web:tab-1", enqueued_id: "e1" } }

    it "tags the turn's boundary events with who queued it" do
      allow(kernel).to receive(:run).and_return(kernel_result)

      events = events_of(origin: origin)

      expect(events.first).to match(type: :turn_started, session_id: session.id, prompt: "hi", origin: origin,
                                 turn_id: a_string_matching(/\A\h{8}-/))
      expect(events.find { |e| e[:type] == :turn_completed }).to include(origin: origin)
    end

    it "tags :turn_canceled and :turn_failed too" do
      allow(kernel).to receive(:run).and_return(kernel_result(canceled: true, cancellation_reason: :manual))
      expect(events_of(origin: origin).last).to include(type: :turn_canceled, origin: origin)

      allow(kernel).to receive(:run).and_raise(Interrupt)
      events = []
      expect { engine.run_turn(session, "hi", on_event: ->(e) { events << e }, origin: origin) }.to raise_error(Interrupt)
      expect(events.last).to include(type: :turn_canceled, origin: origin)

      allow(kernel).to receive(:run).and_raise(RuntimeError, "boom")
      events = []
      expect { engine.run_turn(session, "hi", on_event: ->(e) { events << e }, origin: origin) }.to raise_error(RuntimeError)
      expect(events.last).to include(type: :turn_failed, origin: origin)
    end

    it "adds no origin key when none is given" do
      allow(kernel).to receive(:run).and_return(kernel_result)

      expect(events_of.select { |e| e.key?(:origin) }).to be_empty
    end
  end

  it "appends a cancel note, not [No response], to a canceled turn" do
    allow(kernel).to receive(:run).and_return(
      kernel_result(text: "", conversation: [{ role: "user", content: "hi" }], canceled: true, cancellation_reason: :ctrl_c)
    )

    result = engine.run_turn(session, "hi")

    expect(session.messages.first).to eq({ role: "user", content: "hi" })
    expect(session.messages.last).to include(role: "system", kind: "turn_note")
    expect(session.messages.last[:content]).to include("cancelled (ctrl-c)").and include("no answer had been shown")
    expect(session.messages.length).to eq(2)
    # The REPL keeps result.conversation: the note is there too.
    expect(result.conversation.last).to eq(session.messages.last)
  end

  it "says a cancelled answer was cut off when the tail is [interrupted]" do
    allow(kernel).to receive(:run).and_return(
      kernel_result(text: "", conversation: [{ role: "user", content: "hi" }, { role: "model", content: "Riv\n[interrupted]", interrupted: true }],
                    canceled: true, cancellation_reason: :user)
    )

    engine.run_turn(session, "hi")

    expect(session.messages.last[:content]).to include("cancelled (user)").and include("the answer above ends where it was cut off")
  end

  it "leaves a turn that can be continued ending at its tool results, with no [No response] placeholder" do
    allow(kernel).to receive(:run).and_return(
      kernel_result(text: "", conversation: [{ role: "tool_response", content: "r" }], exhausted: true, pending_tool_calls: true)
    )

    result = engine.run_turn(session, "hi")

    expect(result.conversation).to eq([{ role: "tool_response", content: "r" }])
    expect(session.messages).to eq([{ role: "tool_response", content: "r" }])
  end

  it "saves an ordinary empty reply as the note alone, with the marker the UIs draw from" do
    steps = [{ role: "model", content: "<think>a</think>" }, { role: "model", content: "", thinking: "b" }]
    allow(kernel).to receive(:run).and_return(kernel_result(text: "", conversation: [{ role: "user", content: "hi" }],
                                                            empty_steps: steps, empty_retries: 1))

    result = engine.run_turn(session, "hi")

    expect(result.conversation.first).to eq({ role: "user", content: "hi" })
    expect(result.conversation.last).to include(kind: "turn_note", empty_answer: { retries: 1, steps: steps })
    expect(result.conversation.length).to eq(2)
    expect(session.messages.map { |m| m[:content] }).not_to include("[No response]")
    expect(session.messages.last).to eq(result.conversation.last)
  end

  describe "Interrupt" do
    it "keeps the prompt in the session, emits :turn_canceled and re-raises" do
      allow(kernel).to receive(:run).and_raise(Interrupt)
      events = []

      expect { engine.run_turn(session, "hi", on_event: ->(e) { events << e }) }.to raise_error(Interrupt)

      expect(session.messages.map { |m| m[:role] }).to eq(%w[system user system])
      expect(session.messages[-2][:content]).to eq("hi")
      expect(session.messages.last[:content]).to include("cancelled (ctrl-c)")
      expect(events.last).to match(type: :turn_canceled, cancellation_reason: :ctrl_c, duration_ms: kind_of(Integer))
      expect(engine.turn_running?).to be(false)
      expect(engine.metrics.snapshot[:cancellations]).to eq(1)
    end
  end

  it "emits :turn_failed and closes the metrics turn when the kernel raises" do
    error = Samagotchi::Client::RetryExhausted.new(attempts: 4, last_error: Errno::ECONNREFUSED.new)
    allow(kernel).to receive(:run).and_raise(error)
    events = []

    expect { engine.run_turn(session, "hi", on_event: ->(e) { events << e }) }.to raise_error(error)

    expect(events.last).to include(type: :turn_failed, error_class: "Samagotchi::LLM::RetryExhausted")
    expect(engine.metrics.snapshot[:turn_records].last).to include(status: "failed")
  end

  it "says in :turn_failed what kind of provider error ended the turn" do
    error = Samagotchi::LLM::RateLimited.new("fw: HTTP 429: slow down", host: "fw", status: 429, retry_after: 20.0)
    allow(kernel).to receive(:run).and_raise(error)
    events = []

    expect { engine.run_turn(session, "hi", on_event: ->(e) { events << e }) }.to raise_error(error)

    expect(events.last).to include(type: :turn_failed, error_kind: :rate_limited, retryable: true, host: "fw",
                                   summary: "rate limited by host fw: HTTP 429: slow down; retry after 20s")
  end

  it "adds no provider fields for other errors" do
    allow(kernel).to receive(:run).and_raise(RuntimeError, "boom")
    events = []

    expect { engine.run_turn(session, "hi", on_event: ->(e) { events << e }) }.to raise_error(RuntimeError)

    expect(events.last.keys).to contain_exactly(:type, :error_class, :message, :duration_ms)
  end

describe "a failed turn" do
  it "keeps the prompt and the loop's completed iterations in the session, and saves it" do
    partial = [{ role: "system", content: "sys" }, { role: "user", content: "hi" },
               { role: "model", content: "calling" }, { role: "tool_response", content: "[execute]\nok" }]
    error = Samagotchi::LLM::FailedTurn.attach(RuntimeError.new("boom"), partial)
    allow(kernel).to receive(:run).and_raise(error)
    allow(session).to receive(:save)

    expect { engine.run_turn(session, "hi") }.to raise_error(RuntimeError, "boom")

    expect(session.messages.first(4)).to eq(partial)
    expect(session.messages.last).to eq({ role: "system", kind: "turn_note",
                                          content: "[SYSTEM: the previous turn failed before any answer: boom. The user's last message was not answered.]" })
    expect(session).to have_received(:save)
  end

  it "keeps at least the prompt when the loop hands nothing back" do
    allow(kernel).to receive(:run).and_raise(RuntimeError, "boom")
    allow(session).to receive(:save)

    expect { engine.run_turn(session, "hi") }.to raise_error(RuntimeError)

    expect(session.messages.map { |m| m[:role] }).to eq(%w[system user system])
    expect(session.messages[-2][:content]).to eq("hi")
  end

  it "leaves one note when the turn fails again, and says so for a continue turn" do
    allow(kernel).to receive(:run).and_raise(RuntimeError, "boom")
    allow(session).to receive(:save)
    expect { engine.run_turn(session, "hi") }.to raise_error(RuntimeError)
    session.messages = session.messages.dup

    expect { engine.run_turn(session, nil, continue: true) }.to raise_error(RuntimeError)

    notes = session.messages.select { |m| Samagotchi::TurnNote.note?(m) }
    expect(notes.length).to eq(1)
    expect(notes.first[:content]).to include("The continued turn stopped there.")
  end
end

  describe "system prompt stability" do
    it "reuses the first turn's system prompt even when the memory index changes" do
      index = "v1"
      allow(Samagotchi::Tools::MemoryRead).to receive(:call) { index }
      sent = []
      allow(kernel).to receive(:run) { |messages, **| sent << messages.first[:content]; kernel_result(conversation: messages + [{ role: "model", content: "done" }]) }

      engine.run_turn(session, "one")
      index = "v2"
      engine.run_turn(session, "two")

      expect(sent[1]).to eq(sent[0])
      expect(sent[0]).to include("v1")
    end

    it "rebuilds it after a model switch" do
      sent = []
      allow(kernel).to receive(:run) { |messages, **| sent << messages.first[:content]; kernel_result(conversation: messages) }

      engine.run_turn(session, "one")
      engine.switch_model!("Qwen3-14B")
      engine.run_turn(session, "two")

      expect(sent[1]).not_to eq(sent[0])
      expect(sent[1]).to include("<tools>")
    end
  end

  describe "session messages API" do
    before { engine.session = session }

    it "appends copies of out-of-turn messages" do
      session.messages = [{ role: "system", content: "s" }]
      extra = { role: "user", content: "!(ls)\nout" }

      engine.append_messages([extra])
      extra[:content] = "mutated"

      expect(session.messages).to eq([{ role: "system", content: "s" }, { role: "user", content: "!(ls)\nout" }])
    end

    it "rolls back to a checkpoint" do
      session.messages = [{ role: "system", content: "s" }]
      checkpoint = engine.messages_checkpoint
      engine.append_messages([{ role: "user", content: "later" }])

      engine.rollback_to(checkpoint)

      expect(session.messages).to eq([{ role: "system", content: "s" }])
    end

    it "requires a current session" do
      expect { described_class.new(client: client, kernel: kernel).append_messages([]) }
        .to raise_error(ArgumentError, /no current session/)
    end
  end
end
