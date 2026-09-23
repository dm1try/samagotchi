# frozen_string_literal: true

require "tmpdir"
require "samagotchi/kernel_loop"
require "samagotchi/hooks"
require "samagotchi/llm/chat_loop"
require_relative "../support/fake_chat_adapter"

# How each loop wraps a single tool call: the text the model gets back, the
# tool_call_started/completed events, the before/after hooks, the veto and
# the output cap. Both loops run a REAL KernelLoop dispatch (not a fake
# kernel), so wrapping bugs show up. Native is the reference; the chat loop
# expectations document where it differs from native.
RSpec.describe "Tool call wrapper parity" do
  let(:dir) { Dir.mktmpdir("wrapper-parity") }
  let(:file) { File.join(dir, "notes.txt").tap { |p| File.write(p, "hello from the file\n") } }
  let(:hooks) { Samagotchi::Hooks::Registry.new }
  let(:fired) { [] }
  let(:events) { [] }
  let(:on_event) { ->(e) { events << e } }

  before do
    hooks.register(:before_tool_call) { |e| fired << [:before_tool_call, e[:params]] }
    hooks.register(:after_tool_call) { |e| fired << [:after_tool_call, e[:output]] }
  end

  after { FileUtils.rm_rf(dir) }

  def started = events.find { |e| e[:type] == :tool_call_started }
  def completed = events.find { |e| e[:type] == :tool_call_completed }

  # ── Native (raw-prompt KernelLoop) ────────────────────────────────────────

  def run_native(max_tool_output_chars: nil)
    client = double("client", context_window: nil)
    allow(client).to receive(:complete).and_return(
      %(<|tool_call>call:read{path: "#{file}"}<tool_call|>), "done"
    )
    kernel = Samagotchi::KernelLoop.new(client: client, hooks: hooks, profile: "gemma4")
    result = kernel.run([{ role: "user", content: "read it" }], on_stream_event: on_event,
                        max_tool_output_chars: max_tool_output_chars)
    tool_response = result.conversation.find { |m| m[:role] == "tool_response" }
    [result, tool_response[:content]]
  end

  # ── Chat loop ─────────────────────────────────────────────────────────────

  def run_chat(max_tool_output_chars: nil)
    kernel = Samagotchi::KernelLoop.new(client: double("client", context_window: nil), hooks: hooks, profile: "gemma4")
    adapter = FakeChatAdapter.new(FakeChatAdapter.tools(["c1", "read", { "path" => file }]), FakeChatAdapter.text("done"))
    backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter)
    result = backend.complete(messages: [{ role: "user", content: "read it" }], on_stream_event: on_event,
                              max_tool_output_chars: max_tool_output_chars)
    tool_response = result.conversation.find { |m| m[:role] == "tool_response" }
    [result, tool_response[:content]]
  end

  describe "a normal call" do
    it "native: the model gets one [read] prefix; params, hooks and activity are filled" do
      result, seen = run_native
      expect(seen).to start_with("[read]\n")
      expect(seen).not_to include("[read]\n[read]")
      expect(seen).to include("hello from the file")
      expect(started[:params]).to start_with(%(path="#{dir[0, 20]}))
      expect(completed[:output]).to eq(seen)
      expect(completed[:activity]).to include(tool: "read", status: "ok")
      expect(fired.map(&:first)).to eq(%i[before_tool_call after_tool_call])
      expect(result.tool_activity).to eq([completed[:activity]])
    end

    it "chat: the same params, hooks and tool_activity" do
      result, seen = run_chat
      expect(seen).to start_with("[read]\n")
      expect(seen).not_to include("[read]\n[read]")
      expect(seen).to include("hello from the file")
      expect(started[:params]).to start_with(%(path="#{dir[0, 20]}))
      expect(completed[:output]).to eq(seen)
      expect(completed[:activity]).to include(tool: "read", status: "ok")
      expect(fired.map(&:first)).to eq(%i[before_tool_call after_tool_call])
      expect(fired.first.last).to start_with(%(path="#{dir[0, 20]}))
      expect(result.tool_activity).to eq([completed[:activity]])
    end
  end

  describe "a vetoed call" do
    before { hooks.register(:before_tool_call) { |e| e[:blocked] = true; e[:block_reason] = "nope" } }

    it "native: one [read] prefix on the veto text, status blocked, after_tool_call still fires" do
      _result, seen = run_native
      expect(seen).to eq("[read] Error: blocked by guardrail: nope")
      expect(completed[:activity]).to include(tool: "read", status: "blocked")
      expect(fired.map(&:first)).to eq(%i[before_tool_call after_tool_call])
    end

    it "chat: the same veto text" do
      _result, seen = run_chat
      expect(seen).to eq("[read] Error: blocked by guardrail: nope")
      expect(completed[:activity]).to include(tool: "read", status: "blocked")
      expect(fired.map(&:first)).to eq(%i[before_tool_call after_tool_call])
    end
  end

  describe "a raising tool" do
    before { allow(Samagotchi::Tools::Read).to receive(:call).and_raise(RuntimeError, "boom") }

    it "native: dispatch turns it into a prefixed error" do
      _result, seen = run_native
      expect(seen).to eq("[read] Error: boom")
      expect(completed[:activity]).to include(tool: "read", status: "error")
    end

    it "chat: the same prefixed error" do
      _result, seen = run_chat
      expect(seen).to eq("[read] Error: boom")
      expect(completed[:activity]).to include(tool: "read", status: "error")
    end
  end

  describe "output over the cap" do
    it "native: only the event is capped; the model gets the full output" do
      _result, seen = run_native(max_tool_output_chars: 10)
      expect(seen).to include("hello from the file")
      expect(completed[:output]).to eq(seen[0, 10])
      expect(completed[:output_truncated]).to be(true)
      expect(fired.last).to eq([:after_tool_call, seen[0, 10]])
    end

    it "both loops take the cap from config when no override is given" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("max_tool_output_chars").and_return(12)
      run_native
      native_cap = completed[:output].length
      events.clear
      run_chat
      expect([native_cap, completed[:output].length]).to eq([12, 12])
    end

    it "chat: the model gets the capped output (a per-loop choice, kept)" do
      _result, seen = run_chat(max_tool_output_chars: 10)
      expect(completed[:output].length).to eq(10)
      expect(completed[:output_truncated]).to be(true)
      expect(seen).to eq(completed[:output])
      expect(fired.last).to eq([:after_tool_call, completed[:output]])
    end
  end
end
