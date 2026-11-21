# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/block_fix"
require "samagotchi/answer_display"
require "samagotchi/session"
require "samagotchi/llm/chat_loop"
require_relative "support/fake_chat_adapter"
require_relative "support/test_kernel"

# A block fix's stamp (BlockFix::STAMP) is display only, and survives what
# rebuilds a conversation: a save and a load, and a real turn on each loop
# (both rebuild every message from an allowlist at a turn's end).
RSpec.describe "a block fix's stamp" do
  include TestKernel

  let(:stamp) { [Samagotchi::BlockFix.entry(key: "k" * 32, fixed_key: "f" * 32, state: "fixed")] }
  let(:answer) { { role: "model", content: "```mermaid\ngraph LR\n```", Samagotchi::BlockFix::STAMP => stamp } }

  it "is display only: nothing model-facing sees it" do
    expect(Samagotchi::AnswerDisplay::DISPLAY_ONLY).to include("block_fixes")
    expect(Samagotchi::AnswerDisplay.strip(answer)).to eq(role: "model", content: answer[:content])
  end

  it "round-trips a save and a load, read back through its accessor" do
    Dir.mktmpdir do |dir|
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: dir)
      session.messages = [{ role: "user", content: "draw" }, answer]
      session.save(state_dir: dir)
      loaded = Samagotchi::Session.load(session.id, state_dir: dir)
      expect(Samagotchi::BlockFix.stamps(loaded.messages.last)).to eq(stamp)
    end
  end

  it "survives a real ChatLoop turn, and the request doesn't carry it" do
    adapter = FakeChatAdapter.new(FakeChatAdapter.text("next answer"))
    kernel = test_kernel
    backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter)
    messages = [{ role: "user", content: "draw" }, answer, { role: "user", content: "and now?" }]
    result = backend.complete(messages: messages, model_name: "m", on_stream_event: ->(_) {},
                              context: run_context(settings: kernel.turn_settings, tools: kernel.tools))

    kept = result.conversation.find { |m| m[:content] == answer[:content] }
    expect(kept[Samagotchi::BlockFix::STAMP]).to eq(stamp)
    expect(adapter.requests.to_s).not_to include("f" * 32)
  end

  it "survives KernelLoop#prepare_conversation, with or without kept thoughts" do
    kernel = test_kernel
    [nil, 0].each do |keep|
      prepared = kernel.send(:prepare_conversation, [{ role: "user", content: "draw" }, answer], keep_thought_from: keep)
      expect(prepared.last[Samagotchi::BlockFix::STAMP]).to eq(stamp)
    end
  end
end
