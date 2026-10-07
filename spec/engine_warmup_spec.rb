# frozen_string_literal: true

require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"
require "support/test_kernel"

# The turn-end warm-up (PromptWarmup): after a completed turn on a local
# llama.cpp host, the next turn's prompt up to its user message is sent on
# the slot the turn's last request used.
RSpec.describe Samagotchi::Engine, "turn-end warm-up", :warmup do
  around do |example|
    with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Ornith") do
      Dir.mktmpdir("chi-state") do |dir|
        @state_dir = dir
        example.run
      end
    end
  end

  let(:warmups) { Queue.new }
  let(:client) do
    test_client.tap do |c|
      allow(c).to receive(:warm_up) do |prompt, **kwargs|
        warmups << kwargs.merge(prompt: prompt)
        Samagotchi::Client::Warmup.new(slot: kwargs[:slot], cache_n: 1, prompt_n: 1, prompt_ms: 1)
      end
    end
  end
  let(:kernel) { test_kernel(client: client, profile: Samagotchi::ModelProfile.qwen36) }
  let(:engine) do
    described_class.new(client: client, kernel: kernel, profile: "qwen36").tap { |e| e.session_state_dir = @state_dir }
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Ornith", working_directory: Dir.pwd) }
  let(:result_options) { {} }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(client).to receive(:complete) do |_prompt, on_chunk: nil, **|
      on_chunk&.call(content: "Answer", payload: { "content" => "Answer", "id_slot" => 2 })
      "Answer"
    end
  end

  def sent_warmups
    engine.prompt_warmup.wait(2)
    Array.new(warmups.size) { warmups.pop }
  end

  it "sends the next turn's prompt head on the last request's slot" do
    engine.run_turn(session, "hi")

    sent = sent_warmups
    expect(sent.size).to eq(1)
    expect(sent.first).to include(slot: 2, model: "Ornith")
    expect(sent.first[:prompt]).to start_with("<|im_start|>system\n")
    expect(sent.first[:prompt]).to end_with("<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\nAnswer<|im_end|>\n")
  end

  it "warms the prompt under the next turn's strategy, resolved again after the turn (a /model switch)" do
    during = Samagotchi::LLMContextStrategy::Resolved.new(layers: [], strategy: :none, source: :config)
    after = Samagotchi::LLMContextStrategy::Resolved.new(layers: [:stale], strategy: [:stale], source: :model_setting)
    allow(Samagotchi::LLMContextStrategy).to receive(:resolve).and_return(during, after)
    allow(kernel).to receive(:warmup_prompt).and_call_original

    engine.run_turn(session, "hi")
    sent_warmups

    expect(kernel).to have_received(:warmup_prompt).with(anything, llm_context: after)
  end

  it "warms under the last turn's strategy when the next one can't be resolved" do
    during = Samagotchi::LLMContextStrategy::Resolved.new(layers: [:stale], strategy: [:stale], source: :config)
    calls = 0
    allow(Samagotchi::LLMContextStrategy).to receive(:resolve) do
      calls += 1
      calls == 1 ? during : raise(ArgumentError, "bad config")
    end
    allow(kernel).to receive(:warmup_prompt).and_call_original

    engine.run_turn(session, "hi")
    sent_warmups

    expect(kernel).to have_received(:warmup_prompt).with(anything, llm_context: during)
  end

  it "is off with cache.warmup off" do
    with_env("SAMAGOTCHI_CACHE_WARMUP" => "off") { engine.run_turn(session, "hi") }

    expect(sent_warmups).to be_empty
  end

  it "skips a turn whose next one starts at once or differs anyway" do
    engine.next_turn_waiting = -> { true }
    engine.run_turn(session, "queued input")
    engine.next_turn_waiting = nil
    allow(engine).to receive(:reminders_due?).and_return(true)
    engine.run_turn(session, "a reminder is due")

    expect(sent_warmups).to be_empty
  end

  it "skips a turn that ran out of steps (a continue offer)" do
    allow(kernel).to receive(:run) do |messages, **|
      Samagotchi::LLM::ModelResult.new(text: "", conversation: messages + [{ role: "tool_response", content: "[read] x" }],
                                       exhausted: true, pending_tool_calls: true, tool_activity: [], canceled: false)
    end

    engine.run_turn(session, "hi")

    expect(sent_warmups).to be_empty
  end

  it "never warms a remote host" do
    allow_any_instance_of(Samagotchi::HostRegistry::HostEntry).to receive(:remote?).and_return(true)

    engine.run_turn(session, "hi")

    expect(sent_warmups).to be_empty
  end

  it "pins the next turn's first request while the warm-up still runs" do
    gate = Queue.new
    allow(client).to receive(:warm_up) do
      gate.pop
      nil
    end
    slots = []
    allow(client).to receive(:complete) do |_prompt, on_chunk: nil, slot: nil, **|
      slots << slot
      on_chunk&.call(content: "Answer", payload: { "content" => "Answer", "id_slot" => 2 })
      "Answer"
    end

    engine.run_turn(session, "hi")
    engine.run_turn(session, "again")
    gate << :go
    gate << :go
    engine.prompt_warmup.wait(2)

    expect(slots).to eq([nil, 2])
  end
end
