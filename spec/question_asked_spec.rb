# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/engine"
require "samagotchi/hooks"
require "samagotchi/question_asked"
require "samagotchi/session"
require "samagotchi/llm/chat_loop"
require "samagotchi/llm/openai_chat"
require "samagotchi/llm/anthropic_messages"
require "support/thinking_off"
require_relative "support/fake_chat_adapter"
require "support/test_kernel"

# The :question_asked hook event (QuestionAsked): fired when a question of
# the model's or an approval of its call opens, its refs kept on the
# asking step (display only) and on the pending question.
RSpec.describe Samagotchi::QuestionAsked do
  let(:registry) { Samagotchi::Hooks::Registry.new }
  let(:fields) { { question: "Proceed with DEMO-123?", options: %w[Yes No], header: "Ticket" } }
  let(:step) { { role: "model", content: "<|channel>thought\nhmm<channel|>About DEMO-123.<|tool_response|>" } }
  let(:conversation) { [{ role: "user", content: "go" }, step] }

  def ref(key, url = "https://example.test/browse/#{key}")
    { match: key, kind: "issue", target: { id: key }, label: "DEMO #{key}",
      actions: [{ id: "open", label: "Open in DEMO", url: url }] }
  end

  def on_question(&block) = registry.register_bundle("b", :question_asked, hook_name: "q.rb", &block)

  def fire(conversation: self.conversation, kind: "question", fields: self.fields)
    described_class.fire(hooks: registry, conversation: conversation, kind: kind, fields: fields, cwd: Dir.pwd)
  end

  it "does nothing with no subscriber: the fields come back as they were, no collector built" do
    expect(Samagotchi::AnswerRefs).not_to receive(:new)

    expect(fire).to be(fields)
    expect(step).not_to have_key(:display_refs)
  end

  it "gives the hooks the kind, the step's text without markup, a frozen copy of the question and a refs adder" do
    seen = nil
    on_question { |event| seen = event }

    fire(kind: "approval")

    expect(seen).to include(type: :question_asked, kind: "approval", text: "About DEMO-123.", question: fields)
    expect(seen[:question]).to be_frozen
    expect(seen[:question][:options]).to be_frozen
    expect(seen[:refs]).to respond_to(:call)
  end

  it "keeps the refs on the step, in place, and returns the fields with them" do
    on_question { |event| event[:refs].call(**ref("DEMO-123")) }

    opened = fire

    expect(opened).to eq(fields.merge(refs: [ref("DEMO-123")]))
    expect(conversation.last).to be(step)
    expect(step[:display_refs]).to eq([ref("DEMO-123")])
  end

  it "targets the last model entry, not a tool result after it (a chat batch's earlier result)" do
    model = { role: "model", content: "Reading, then asking about DEMO-123.", tool_calls: [{ id: "c1" }, { id: "c2" }] }
    result = { role: "tool", tool_call_id: "c1", content: "[read]\nfile text" }
    on_question { |event| event[:refs].call(**ref("DEMO-123")) }

    fire(conversation: [{ role: "user", content: "go" }, model, result])

    expect(model[:display_refs]).to eq([ref("DEMO-123")])
    expect(result).not_to have_key(:display_refs)
  end

  it "merges two questions of one step: the second starts from the first's refs" do
    first = true
    on_question do |event|
      event[:refs].call(**ref(first ? "DEMO-1" : "DEMO-2"))
      first = false
    end

    fire
    second = fire

    expect(step[:display_refs]).to eq([ref("DEMO-1"), ref("DEMO-2")])
    expect(second[:refs]).to eq([ref("DEMO-1"), ref("DEMO-2")])
  end

  it "holds a question's refs to its caps, the refused logged as refs_rejected" do
    warned = []
    allow(Samagotchi::Log).to receive(:warn) { |tag, name, **f| warned << [tag, name, f[:reason]] }
    results = []
    on_question { |event| (1..51).each { |n| results << event[:refs].call(**ref("DEMO-#{n}")) } }

    opened = fire

    expect(opened[:refs].length).to eq(described_class::MAX_REFS)
    expect(results.last).to be(false)
    expect(warned).to include([:hooks, "refs_rejected", "over the cap (50 refs)"])
  end

  it "opens the question when a hook raises, with the other hooks' refs" do
    allow(Samagotchi::Log).to receive(:exception)
    registry.register_bundle("a", :question_asked, hook_name: "boom.rb", priority: 1) { raise "boom" }
    on_question { |event| event[:refs].call(**ref("DEMO-123")) }

    expect(fire).to eq(fields.merge(refs: [ref("DEMO-123")]))
  end

  it "makes event[:ask_user] a no-op (nil): a question would wait inside the one opening" do
    answer = :unset
    on_question { |event| answer = event[:ask_user].call(question: "q?", options: %w[a b]) }

    fire

    expect(answer).to be_nil
  end

  it "has no step to attach to without a model entry: the call is nil and the fields stay" do
    kept = :unset
    on_question { |event| kept = event[:refs].call(**ref("DEMO-123")) }

    expect(fire(conversation: [{ role: "user", content: "go" }])).to eq(fields)
    expect(kept).to be_nil
  end

  it "a session reload keeps the pending question's refs (PendingQuestion#refs)" do
    pending = Samagotchi::PendingQuestion.new(id: "q1", question: "q?", refs: [ref("DEMO-1")])

    expect(pending.to_h[:refs]).to eq([ref("DEMO-1")])
    reloaded = Samagotchi::PendingQuestion.from_file(JSON.parse(JSON.generate(pending.to_file)))
    expect(reloaded.refs.first["match"]).to eq("DEMO-1")
    expect(Samagotchi::PendingQuestion.new(id: "q2").to_h).not_to have_key(:refs)
  end
end

RSpec.describe "The :question_asked event in a turn" do
  include_context "thinking off"

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { Samagotchi::Engine.new(client: client, kernel: kernel, profile: "gemma4").tap { |e| e.interface = :repl } }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:hooks) { engine.instance_variable_get(:@hooks) }
  let(:fired) { [] }
  let(:asked) { [] }
  let(:ask_call) { %(<|tool_call>call:ask_user_question{question: "Proceed with DEMO-123?", options: ["Yes", "No"]}<tool_call|>) }
  let(:demo_ref) do
    { match: "DEMO-123", kind: "issue", target: { id: "DEMO-123" }, label: "DEMO DEMO-123",
      actions: [{ id: "open", label: "Open in DEMO", url: "https://example.test/browse/DEMO-123" }] }
  end
  let(:prompts) { [] }

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

  def native(*replies)
    allow(client).to receive(:complete) do |prompt, **|
      prompts << prompt
      replies.length > 1 ? replies.shift : replies.first
    end
  end

  def subscribe
    hooks.register_bundle("b", :question_asked, hook_name: "q.rb") do |event|
      fired << event.slice(:kind, :text, :question)
      event[:refs].call(**demo_ref) if event[:text].include?("DEMO-123")
    end
  end

  def answer_with(&pick)
    engine.set_question_sync_handler do |pending|
      asked << pending
      choice = pick ? yield(pending) : pending[:options].first
      # An approval maps its answer to a scope by index.
      { selected: [choice], selected_indices: [pending[:options].index(choice)] }
    end
  end

  def step_with(text) = session.messages.find { |m| m[:role] == "model" && m[:content].to_s.include?(text) }

  # The prompts' and requests' text with what differs between two runs
  # (session ids, turn ids, question ids) put in its place.
  def same_bytes(texts) = texts.map { |text| text.to_s.gsub(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/, "UUID").gsub(/sid=\h{8}/, "sid=SID") }

  describe "on the native loop (KernelLoop)" do
    it "fires once for the model's question: the text without thoughts or markup, refs on the step and the pending question" do
      native("Asking about DEMO-123.#{ask_call}", "done")
      subscribe
      answer_with

      engine.run_turn(session, "go")

      expect(fired).to eq([{ kind: "question", text: "Asking about DEMO-123.",
                             question: { question: "Proceed with DEMO-123?", options: %w[Yes No],
                                         multi_select: false, allow_freeform: false } }])
      expect(asked.map { |pending| pending[:refs] }).to eq([[demo_ref]])
      expect(step_with("Asking about")[:display_refs]).to eq([demo_ref])
    end

    it "saves the refs with the pending question (session.json), so a reload mid-wait has them" do
      native("Asking about DEMO-123.#{ask_call}", "done")
      subscribe
      loaded = nil
      engine.set_question_sync_handler do |pending|
        loaded = Samagotchi::Session.load(session.id).pending_question
        { selected: [pending[:options].first] }
      end

      engine.run_turn(session, "go")

      expect(loaded.refs.map { |r| r["match"] }).to eq(["DEMO-123"])
      session.save
      step = Samagotchi::Session.load(session.id).messages.find { |m| (m[:content] || m["content"]).to_s.include?("Asking about") }
      expect(JSON.parse(JSON.generate(step[:display_refs] || step["display_refs"]))).to eq([JSON.parse(JSON.generate(demo_ref))])
    end

    it "fires once per approval of the model's call (kind approval), with the step's refs on each" do
      read = %(About DEMO-123, reading it.<|tool_call>call:read{path: "README.md"}<tool_call|>)
      native(read, "done")
      subscribe
      hooks.register_persistent(:before_tool_call) { |event| event[:guardrail].ask!("check it") if event[:call][:name] == "read" }
      answer_with

      engine.run_turn(session, "go")

      expect(fired.map { |f| [f[:kind], f[:text]] }).to eq([["approval", "About DEMO-123, reading it."]])
      expect(fired.first[:question]).to include(kind: "approval", header: "Approve tool call?")
      expect(asked.map { |pending| pending[:refs] }).to eq([[demo_ref]])
      expect(session.messages.find { |m| m[:role] == "tool_response" }[:content]).to start_with("[read]\n")
    end

    it "doesn't fire again for a call the session allowed (a stored approval never asks)" do
      read = %(About DEMO-123, reading it.<|tool_call>call:read{path: "README.md"}<tool_call|>)
      native(read, read, "done")
      subscribe
      hooks.register_persistent(:before_tool_call) { |event| event[:guardrail].ask!("check it") if event[:call][:name] == "read" }
      answer_with { |pending| pending[:options].find { |o| o.include?("session") } }

      engine.run_turn(session, "go")

      expect([fired.length, asked.length]).to eq([1, 1])
      expect(session.messages.select { |m| m[:role] == "tool_response" }.map { |m| m[:content][0, 7] }).to eq(["[read]\n"] * 2)
    end

    it "doesn't fire for a hook's question, the step-limit question, a call ask_user_question refuses, or Engine#open_question" do
      nine = (1..9).map { |n| %("o#{n}") }.join(", ")
      native(%(<|tool_call>call:ask_user_question{question: "Which?", options: [#{nine}]}<tool_call|>), "done")
      subscribe
      hooks.register_persistent(:before_tool_call) do |event|
        event[:ask_user].call(question: "Let it run?", options: %w[Run Deny]) if event[:call][:name] == "ask_user_question"
      end
      answer_with

      engine.run_turn(session, "go")
      engine.open_question(question: "Relayed?", options: %w[Allow Deny], kind: "approval")
      engine.post_question({ question: "Continue?", options: %w[Continue Stop], kind: "continue" }, on_answer: ->(*, **) {})
      engine.withdraw_question("done")

      expect(asked.map { |pending| pending[:question] }).to eq(["Let it run?", "Relayed?"])
      expect(fired).to eq([])
    end

    it "doesn't fire in a --non-interactive run (no one to ask)" do
      native("Asking about DEMO-123.#{ask_call}", %(<|tool_call>call:read{path: "README.md"}<tool_call|>), "done")
      subscribe
      hooks.register_persistent(:before_tool_call) { |event| event[:guardrail].ask!("check it") if event[:call][:name] == "read" }
      engine.interface = :non_interactive
      engine.set_question_sync_handler do |_pending|
        engine.cancel_question(Samagotchi::QuestionDesk::UNANSWERABLE_REASON)
        false
      end

      engine.run_turn(session, "go")

      expect(fired).to eq([])
    end

    it "sends byte-identical prompts with and without the step's refs" do
      runs = Array.new(2) do |index|
        prompts.clear
        engine = Samagotchi::Engine.new(client: client, kernel: test_kernel(client: client), profile: "gemma4")
        engine.interface = :repl
        engine.set_question_sync_handler { |pending| { selected: [pending[:options].first] } }
        if index == 1
          engine.instance_variable_get(:@hooks).register_bundle("b", :question_asked, hook_name: "q.rb") do |event|
            event[:refs].call(**demo_ref)
          end
        end
        native("Asking about DEMO-123.#{ask_call}", "done")
        run_session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
        engine.run_turn(run_session, "go")
        expect(run_session.messages.find { |m| m[:content].to_s.include?("Asking") }.key?(:display_refs)).to be(index == 1)
        same_bytes(prompts.dup)
      end

      expect(runs[0].length).to eq(2)
      expect(runs[1]).to eq(runs[0])
      expect(runs[1].join).not_to include("Open in DEMO")
    end

    it "keeps the refs on a cancelled turn's step, and a rollback drops them with the step" do
      native("Asking about DEMO-123.#{ask_call}", "done")
      subscribe
      engine.set_question_sync_handler do |_pending|
        engine.cancel_current_turn!
        engine.cancel_question("turn_canceled")
        false
      end
      session.messages = [{ role: "user", content: "earlier" }, { role: "model", content: "ok" }]
      checkpoint = engine.tap { |e| e.session = session }.messages_checkpoint

      engine.run_turn(session, "go")

      expect(step_with("Asking about")[:display_refs]).to eq([demo_ref])
      engine.rollback_to(checkpoint)
      expect(session.messages.map { |m| m[:display_refs] }.compact).to eq([])
    end
  end

  describe "on the chat loop (ChatLoop)" do
    def chat(adapter)
      allow(engine).to receive(:backend_for).and_return(Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter))
    end

    it "puts the refs on the model entry of a [read, ask_user_question] batch, not on the read's result" do
      chat(FakeChatAdapter.new(
        FakeChatAdapter.tools(["c1", "read", { "path" => "README.md" }],
                              ["c2", "ask_user_question", { "question" => "Proceed?", "options" => %w[Yes No] }],
                              text: "Reading, then asking about DEMO-123."),
        FakeChatAdapter.text("done")
      ))
      subscribe
      answer_with

      engine.run_turn(session, "go")

      model = step_with("Reading, then asking")
      expect(model[:tool_calls].length).to eq(2)
      expect(model[:display_refs]).to eq([demo_ref])
      expect(session.messages.select { |m| m[:role] == "tool_response" }.map { |m| m.key?(:display_refs) }).to eq([false, false])
      expect(fired.map { |f| [f[:kind], f[:text]] }).to eq([["question", "Reading, then asking about DEMO-123."]])
      expect(asked.first[:refs]).to eq([demo_ref])
    end

    it "fires for an approval of the model's call" do
      chat(FakeChatAdapter.new(FakeChatAdapter.tools(["c1", "read", { "path" => "README.md" }], text: "About DEMO-123."),
                               FakeChatAdapter.text("done")))
      subscribe
      hooks.register_persistent(:before_tool_call) { |event| event[:guardrail].ask!("check it") if event[:call][:name] == "read" }
      answer_with

      engine.run_turn(session, "go")

      expect(fired.map { |f| [f[:kind], f[:text]] }).to eq([["approval", "About DEMO-123."]])
      expect(step_with("About DEMO-123.")[:display_refs]).to eq([demo_ref])
    end

    # Real adapters on stubbed HTTP: what goes on the wire, with and
    # without the step's refs.
    def wire_bodies(adapter, url, responses, with_refs:)
      bodies = []
      stub_request(:get, %r{\Ahttp://fake\.test/v1/models}).to_return(status: 200, body: JSON.generate(data: []))
      stub_request(:post, url).to_return do |request|
        bodies << request.body
        { status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate(responses[bodies.length - 1]) }
      end
      engine = Samagotchi::Engine.new(client: client, kernel: kernel, profile: "gemma4")
      engine.interface = :repl
      engine.set_question_sync_handler { |pending| { selected: [pending[:options].first] } }
      if with_refs
        engine.instance_variable_get(:@hooks).register_bundle("b", :question_asked, hook_name: "q.rb") do |event|
          event[:refs].call(**demo_ref)
        end
      end
      allow(engine).to receive(:backend_for).and_return(Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter))
      run_session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
      engine.run_turn(run_session, "go")
      expect(run_session.messages.find { |m| m[:content].to_s.include?("Asking") }.key?(:display_refs)).to be(with_refs)
      same_bytes(bodies)
    end

    it "sends byte-identical OpenAI chat requests with and without the step's refs" do
      url = "http://fake.test/v1/chat/completions"
      call = { id: "c1", type: "function", function: { name: "ask_user_question",
                                                       arguments: JSON.generate(question: "Proceed?", options: %w[Yes No]) } }
      responses = [
        { choices: [{ message: { role: "assistant", content: "Asking about DEMO-123.", tool_calls: [call] }, finish_reason: "tool_calls" }] },
        { choices: [{ message: { role: "assistant", content: "done" }, finish_reason: "stop" }] }
      ]
      adapter = -> { Samagotchi::LLM::OpenAIChat.new(base_url: "http://fake.test/v1", host_name: "fake", stream: false, retries: false) }

      without = wire_bodies(adapter.call, url, responses, with_refs: false)
      with = wire_bodies(adapter.call, url, responses, with_refs: true)

      expect(without.length).to eq(2)
      expect(with).to eq(without)
      expect(with.join).not_to include("Open in DEMO")
    end

    it "sends byte-identical Anthropic Messages requests with and without the step's refs" do
      url = "http://fake.test/v1/messages"
      usage = { input_tokens: 10, output_tokens: 5 }
      responses = [
        { id: "m1", type: "message", role: "assistant", stop_reason: "tool_use", usage: usage,
          content: [{ type: "text", text: "Asking about DEMO-123." },
                    { type: "tool_use", id: "toolu_1", name: "ask_user_question", input: { question: "Proceed?", options: %w[Yes No] } }] },
        { id: "m2", type: "message", role: "assistant", stop_reason: "end_turn", usage: usage,
          content: [{ type: "text", text: "done" }] }
      ]
      adapter = -> { Samagotchi::LLM::AnthropicMessages.new(base_url: "http://fake.test", host_name: "fake", stream: false, retries: false) }

      without = wire_bodies(adapter.call, url, responses, with_refs: false)
      with = wire_bodies(adapter.call, url, responses, with_refs: true)

      expect(without.length).to eq(2)
      expect(with).to eq(without)
      expect(with.join).not_to include("Open in DEMO")
    end
  end
end
