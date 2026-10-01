# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/engine"
require "samagotchi/hooks"
require "samagotchi/kernel_loop"
require "samagotchi/session"
require "samagotchi/prompt"
require "samagotchi/llm/chat_loop"
require "samagotchi/idle_recap"
require "support/thinking_off"
require_relative "support/fake_chat_adapter"

RSpec.describe Samagotchi::AnswerDisplay do
  let(:answer) { { role: "model", content: "see JIRA-1" } }
  let(:event) { { hook: "links.rb (bundle x)" } }

  it "chains: each call gets the text so far and its result is the display" do
    display = described_class.new([{ role: "user", content: "q" }, answer])
    present = display.presenter(event)

    expect(present.call { |text| text.sub("JIRA-1", "[JIRA-1](u)") }).to eq("see [JIRA-1](u)")
    expect(present.call { |text| "#{text}!" }).to eq("see [JIRA-1](u)!")
    expect(display).to be_changed
    expect(display.text).to eq("see [JIRA-1](u)!")
  end

  it "starts from an earlier display when the answer has one" do
    display = described_class.new([answer.merge(display: "shown")])

    expect(display.presenter(event).call { |text| text }).to eq("shown")
    expect(display).not_to be_changed
  end

  it "leaves the display unchanged when the block raises, returns a non-string, or goes over the cap" do
    display = described_class.new([answer])
    present = display.presenter(event)
    present.call { |text| "#{text}." }

    expect(present.call { raise "boom" }).to eq("see JIRA-1.")
    expect(present.call { 42 }).to eq("see JIRA-1.")
    expect(present.call { nil }).to eq("see JIRA-1.")
    expect(present.call { "x" * (described_class::MAX_CHARS + 1) }).to eq("see JIRA-1.")
    expect(display.text).to eq("see JIRA-1.")
  end

  it "has nothing to present when the conversation does not end with the model's answer" do
    display = described_class.new([answer, { role: "system", kind: "turn_note", content: "[SYSTEM: cancelled]" }])

    expect(display.presenter(event).call { "never" }).to be_nil
    expect(display).not_to be_changed
  end

  it ".strip drops the field (either key type) and keeps other messages as they are" do
    user = { role: "user", content: "q" }

    expect(described_class.strip_all([user, answer.merge(display: "d"), { "role" => "model", "display" => "d" }]))
      .to eq([user, answer, { "role" => "model" }])
    expect(described_class.strip(user)).to be(user)
  end
end

RSpec.describe "Presenting the answer from after_turn" do
  include_context "thinking off"

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:engine) { Samagotchi::Engine.new(client: client, kernel: kernel) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:stored) { [{ role: "user", content: "hi" }, { role: "model", content: "see JIRA-1" }] }
  let(:registry) { engine.instance_variable_get(:@hooks) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run).and_return(
      Samagotchi::KernelLoop::Result.new(output: "see JIRA-1", conversation: stored.map(&:dup), exhausted: false,
                                         pending_tool_calls: false, tool_activity: [])
    )
  end

  def bundle_hook(name, priority, &block)
    registry.register_bundle("b", :after_turn, hook_name: name, priority: priority, &block)
  end

  it "keeps the chained display on the answer, in hook priority order, and leaves content alone" do
    bundle_hook("second.rb", 50) { |e| e[:present].call { |text| "#{text} (2)" } }
    bundle_hook("first.rb", 10) { |e| e[:present].call { |text| text.sub("JIRA-1", "[JIRA-1](https://j/JIRA-1)") } }

    engine.run_turn(session, "hi")

    expect(session.messages.last).to eq(role: "model", content: "see JIRA-1", display: "see [JIRA-1](https://j/JIRA-1) (2)")
  end

  it "announces :answer_display after :turn_completed, with the display already in the messages a re-read serves" do
    bundle_hook("links.rb", 10) { |e| e[:present].call { |text| "#{text}!" } }
    seen = []
    engine.subscribe(observer: lambda { |e|
      next unless %i[turn_completed answer_display].include?(e[:type])

      seen << [e[:type], engine.messages_checkpoint.last[:display], e[:display_pending], e[:display]]
    })

    engine.run_turn(session, "hi")

    # At turn_completed the display is not there yet (the hooks run after
    # it) but may come (display_pending); the web re-reads on
    # :answer_display, when it is.
    expect(seen).to eq([[:turn_completed, nil, true, nil], [:answer_display, "see JIRA-1!", nil, "see JIRA-1!"]])
  end

  it "says so (display: nil) when no hook changed the display, or one failed" do
    bundle_hook("same.rb", 10) { |e| e[:present].call { |text| text } }
    bundle_hook("bad.rb", 20) { |e| e[:present].call { :not_a_string } }
    bundle_hook("raises.rb", 30) { |_e| raise "boom" }
    events = []
    engine.subscribe(observer: ->(e) { events << e.slice(:type, :display_pending, :display) })

    engine.run_turn(session, "hi")

    expect(events.select { |e| %i[turn_completed answer_display].include?(e[:type]) })
      .to eq([{ type: :turn_completed, display_pending: true }, { type: :answer_display, display: nil }])
    expect(session.messages.last).not_to have_key(:display)
  end

  it "promises no display without after_turn hooks" do
    events = []
    engine.subscribe(observer: ->(e) { events << e.slice(:type, :display_pending) })

    engine.run_turn(session, "hi")

    expect(events).to include({ type: :turn_completed, display_pending: false })
    expect(events.map { |e| e[:type] }).not_to include(:answer_display)
  end

  it "saves it in session.json" do
    Dir.mktmpdir do |dir|
      bundle_hook("links.rb", 10) { |e| e[:present].call { |text| "#{text}!" } }
      engine.run_turn(session, "hi")
      session.save(state_dir: dir)

      raw = JSON.parse(File.read(Dir[File.join(dir, "**", "#{session.id}.json")].first))
      expect(raw["messages"].last).to include("content" => "see JIRA-1", "display" => "see JIRA-1!")
      expect(Samagotchi::Session.load(session.id, state_dir: dir).messages.last[:display]).to eq("see JIRA-1!")
    end
  end

  it "gives a cancelled turn nothing to present" do
    allow(kernel).to receive(:run).and_return(
      Samagotchi::KernelLoop::Result.new(output: "", conversation: stored.map(&:dup), exhausted: false, pending_tool_calls: false,
                                         tool_activity: [], canceled: true, cancellation_reason: :manual)
    )
    got = :unset
    bundle_hook("links.rb", 10) { |e| got = e[:present].call { "never" } }

    engine.run_turn(session, "hi")

    expect(got).to be_nil
    expect(session.messages.none? { |m| m.key?(:display) }).to be(true)
  end

  describe "the field never reaches a model-facing reader" do
    let(:marker) { "DISPLAY-ONLY-MARKER" }
    let(:history) { [{ role: "user", content: "old" }, { role: "model", content: "ok", display: marker }] }

    before { session.messages = history.map(&:dup) }

    it "is not in the hooks' copies of the conversation" do
      seen = []
      engine.register_hook(:before_turn) { |e| seen << e[:messages] }
      engine.register_hook(:after_turn) { |e| seen << e[:messages] }

      engine.run_turn(session, "hi")

      expect(seen.size).to eq(2)
      expect(JSON.generate(seen)).not_to include(marker)
    end

    it "is not in the recap's input" do
      engine.instance_variable_set(:@session, session)

      json = engine.messages_json_for_recap

      expect(json).not_to include(marker)
      expect(Samagotchi::IdleRecap::TranscriptFilter.build(JSON.parse(json))).to include("ok")
    end

    it "is not in a plugin's ctx.messages" do
      engine.instance_variable_set(:@session, session)

      expect(JSON.generate(engine.send(:plugin_messages))).not_to include(marker)
    end
  end
end

RSpec.describe "The display field and the model payloads" do
  let(:marker) { "DISPLAY-ONLY-MARKER" }
  let(:history) do
    [{ role: "user", content: "old" }, { role: "model", content: "ok", display: marker }, { role: "user", content: "next" }]
  end

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  it "the native prompt leaves it out, and the stored conversation keeps it" do
    client = instance_double(Samagotchi::Client)
    prompts = []
    allow(client).to receive(:complete) { |prompt, **| prompts << prompt; "fine" }
    registry = Samagotchi::Hooks::Registry.new
    generation = nil
    registry.register(:after_generation) { |e| generation = e[:messages] }

    result = Samagotchi::KernelLoop.new(client: client, hooks: registry).run(history.map(&:dup))

    expect(prompts.join).to include("ok")
    expect(prompts.join).not_to include(marker)
    expect(JSON.generate(generation)).not_to include(marker)
    expect(result.conversation.find { |m| m[:content] == "ok" }).to include(display: marker)
  end

  it "every model profile's prompt formatter leaves it out" do
    [Samagotchi::ModelProfile.gemma4, Samagotchi::ModelProfile.qwen36].each do |profile|
      prompt, = Samagotchi::Prompt.format_with_images(history, profile: profile)
      expect(prompt).not_to include(marker), "profile #{profile.name}"
    end
  end

  it "the chat request leaves it out, and the stored conversation keeps it" do
    kernel = double("kernel", hooks: nil)
    allow(kernel).to receive(:strip_model_thought) { |text| text.to_s }
    adapter = FakeChatAdapter.new(FakeChatAdapter.text("fine"))
    sent = []
    allow(adapter).to receive(:chat).and_wrap_original do |original, **kwargs|
      sent << kwargs[:messages]
      original.call(**kwargs)
    end

    result = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter).complete(messages: history.map(&:dup), model_name: "m")

    expect(JSON.generate(sent)).to include("ok")
    expect(JSON.generate(sent)).not_to include(marker)
    expect(result.conversation.find { |m| m[:content] == "ok" }).to include(display: marker)
  end
end
