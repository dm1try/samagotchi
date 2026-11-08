# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require_relative "support/fake_chat_adapter"
require "support/test_kernel"

# The tool ids a turn saves (ToolIds, on the tool_response entries), pinned
# on both loops through a real Engine turn: a strategy's edits name outputs by
# them (LLMContextView), so they decide request bytes. Pinned before the ids
# are handed out ahead of the runs instead of after them
# (~/.claude/plans/arch-turn-records.md, P1 C0/C1): this spec must stay green
# unchanged across that move.
RSpec.describe "the tool ids a batch saves" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { Samagotchi::Engine.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(session).to receive(:save)
  end

  # The tool calls answer +outputs+ in turn; an :interrupt one raises Interrupt.
  def tool_outputs(*outputs)
    allow(kernel).to receive(:dispatch_tool_call) do |call|
      output = outputs.shift
      raise Interrupt if output == :interrupt

      { output: "[#{call[:name]}]\n#{output}", activity: { tool: call[:name], status: "ok" } }
    end
  end

  def run(prompt)
    engine.run_turn(session, prompt)
  rescue Interrupt => e
    e
  end

  def saved_responses = session.messages.select { |m| m[:role] == "tool_response" }
  def saved_ids = saved_responses.map { |m| m[:tool_ids] }

  def native_batch(*commands)
    commands.map { |command| %(<|tool_call>call:execute{command: "#{command}"}<tool_call|>) }.join
  end

  describe "the native loop (KernelLoop#dispatch_calls)" do
    def answers(*replies)
      allow(client).to receive(:complete) do
        reply = replies.shift
        raise Interrupt if reply == :interrupt

        reply
      end
    end

    it "a 3-call batch, then a 2-call batch in the same turn: one entry per batch, ids in call order" do
      tool_outputs("a", "b", "c", "d", "e")
      answers(native_batch("echo a", "echo b", "echo c"), native_batch("echo d", "echo e"), "done")

      run("go")

      expect(saved_ids).to eq([%w[t1 t2 t3], %w[t4 t5]])
      expect(saved_responses.map { |m| m[:content] })
        .to eq([%w[a b c], %w[d e]].map { |outs| outs.map { |o| "[execute]\n#{o}" }.join(Samagotchi::ToolResponse::SEPARATOR) })
    end

    it "an Interrupt mid-batch after an earlier turn: the finished runs and the stand-ins share one entry's ids" do
      tool_outputs("first", "a", :interrupt)
      answers(native_batch("echo first"), "done", native_batch("echo a", "sleep 9", "echo c"))

      run("one")
      expect(run("two")).to be_a(Interrupt)

      expect(saved_ids).to eq([%w[t1], %w[t2 t3 t4]])
      expect(saved_responses.last[:content])
        .to eq(["[execute]\na", Samagotchi::ToolResponse.interrupted_text("execute"),
                Samagotchi::ToolResponse.interrupted_text("execute")].join(Samagotchi::ToolResponse::SEPARATOR))
    end
  end

  describe "the chat loop (ChatLoop dispatch)" do
    def chat(*steps)
      backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new(*steps))
      allow(engine).to receive(:backend_for).and_return(backend)
    end

    def calls(*ids) = FakeChatAdapter.tools(*ids.map { |id| [id, "execute", { "command" => "echo #{id}" }] })

    it "a 3-call batch, then a 2-call batch in the same turn: one entry and one id per call" do
      tool_outputs("a", "b", "c", "d", "e")
      chat(calls("c1", "c2", "c3"), calls("c4", "c5"), FakeChatAdapter.text("done"))

      run("go")

      expect(saved_ids).to eq([%w[t1], %w[t2], %w[t3], %w[t4], %w[t5]])
      expect(saved_responses.map { |m| m[:tool_call_id] }).to eq(%w[c1 c2 c3 c4 c5])
    end

    it "an Interrupt mid-batch after an earlier turn: the finished run and each stand-in get the next id" do
      tool_outputs("first", "a", :interrupt)
      chat(calls("c0"), FakeChatAdapter.text("done"), calls("c1", "c2", "c3"))

      run("one")
      expect(run("two")).to be_a(Interrupt)

      expect(saved_ids).to eq([%w[t1], %w[t2], %w[t3], %w[t4]])
      expect(saved_responses.map { |m| m[:tool_call_id] }).to eq(%w[c0 c1 c2 c3])
      expect(saved_responses.last(2).map { |m| m[:content] }).to all(eq(Samagotchi::ToolResponse.interrupted_text("execute")))
    end
  end
end
