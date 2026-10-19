# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require_relative "support/fake_chat_adapter"
require "support/test_kernel"

# A Ctrl-C (Interrupt) keeps the turn's progress, as a Stop does: the
# loop's conversation so far (its finished tool iterations), then the
# cancel note. A call the Interrupt cut short is closed with an
# interrupted result, so no call is left without its result.
RSpec.describe Samagotchi::Engine, "#run_turn on Ctrl-C" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(session).to receive(:save)
  end

  def chat(*steps)
    backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new(*steps))
    allow(engine).to receive(:backend_for).and_return(backend)
  end

  # The tool calls answer +outputs+ in turn; a :interrupt one raises Interrupt.
  def tool_outputs(*outputs)
    allow(kernel).to receive(:dispatch_tool_call) do |call|
      output = outputs.shift
      raise Interrupt if output == :interrupt

      { output: "[#{call[:name]}]\n#{output}", activity: { tool: call[:name], status: "ok" } }
    end
  end

  def run(prompt = "hi")
    engine.run_turn(session, prompt)
  rescue Interrupt => e
    e
  end

  def roles_after_prompt
    start = session.messages.rindex { |m| m[:role] == "user" && m[:content] == "hi" }
    session.messages[start..].map { |m| m[:role] }
  end

  def note = session.messages.last[:content]

  describe "the chat loop" do
    it "keeps the finished iteration (the call, its result) before the note" do
      tool_outputs("hi there")
      chat(FakeChatAdapter.tools(["c1", "execute", { "command" => "echo hi" }]), Interrupt.new)

      expect(run).to be_a(Interrupt)

      expect(roles_after_prompt).to eq(%w[user model tool_response system])
      call = session.messages[-3]
      expect(call[:tool_calls]).to eq([{ id: "c1", name: "execute", arguments: { "command" => "echo hi" } }])
      expect(session.messages[-2]).to include(tool_call_id: "c1", content: "[execute]\nhi there")
      expect(note).to start_with("[SYSTEM: the previous turn was cancelled (ctrl-c)")
      expect(session.last_turn.to_file).to include("outcome" => "canceled", "cancel_reason" => "ctrl_c")
    end

    it "closes the calls an Interrupt mid-tool cut short with an interrupted result" do
      tool_outputs("first done", :interrupt)
      chat(FakeChatAdapter.tools(["c1", "execute", { "command" => "true" }], ["c2", "execute", { "command" => "sleep 9" }],
                                 ["c3", "read", { "path" => "x" }]))

      expect(run).to be_a(Interrupt)

      expect(roles_after_prompt).to eq(%w[user model tool_response tool_response tool_response system])
      results = session.messages[-4..-2]
      expect(results.map { |m| m[:tool_call_id] }).to eq(%w[c1 c2 c3])
      expect(results[0][:content]).to eq("[execute]\nfirst done")
      expect(results[1][:content]).to eq(Samagotchi::ToolResponse.interrupted_text("execute"))
      expect(results[2][:content]).to eq(Samagotchi::ToolResponse.interrupted_text("read"))
      # The next request pairs every call with its result.
      wire = Samagotchi::LLM::ChatLoop.new(kernel: kernel).wire_messages(session.messages)
      expect(wire.count { |m| m[:role] == "tool" }).to eq(3)
    end

    it "lists a task the turn started in the note" do
      record = instance_double(Samagotchi::Tools::TaskRecord, running?: true, command: "sleep 99")
      allow(Samagotchi::Tools::TaskRuntime).to receive(:get_record).with("t-42").and_return([record, nil])
      tool_outputs("task_id: t-42")
      chat(FakeChatAdapter.tools(["c1", "task_create", { "command" => "sleep 99" }]), Interrupt.new)

      run

      expect(note).to include("task t-42 (sleep 99)")
    end
  end

  describe "the native loop" do
    it "keeps the finished iteration (the call, its result) before the note" do
      tool_outputs("hi there")
      calls = 0
      allow(client).to receive(:complete) do
        calls += 1
        raise Interrupt if calls > 1

        %(<|tool_call>call:execute{command: "echo hi"}<tool_call|>)
      end

      expect(run).to be_a(Interrupt)

      expect(roles_after_prompt).to eq(%w[user model tool_response system])
      expect(session.messages[-3][:content]).to include("call:execute")
      expect(session.messages[-2][:content]).to eq("[execute]\nhi there")
      expect(note).to start_with("[SYSTEM: the previous turn was cancelled (ctrl-c)")
    end

    it "closes the batch an Interrupt mid-tool cut short: the finished outputs, then interrupted ones" do
      tool_outputs("first done", :interrupt)
      allow(client).to receive(:complete)
        .and_return(%(<|tool_call>call:execute{command: "true"}<tool_call|><|tool_call>call:execute{command: "sleep 9"}<tool_call|>))

      expect(run).to be_a(Interrupt)

      expect(roles_after_prompt).to eq(%w[user model tool_response system])
      response = session.messages[-2]
      expect(response[:content]).to eq(["[execute]\nfirst done", Samagotchi::ToolResponse.interrupted_text("execute")]
                                         .join(Samagotchi::ToolResponse::SEPARATOR))
      expect(response[:tool_ids].size).to eq(2)
    end

    it "keeps only the prompt when the Interrupt comes in the first request" do
      allow(client).to receive(:complete).and_raise(Interrupt)

      run

      expect(roles_after_prompt).to eq(%w[user system])
    end
  end
end
