# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require_relative "support/fake_chat_adapter"
require "support/test_kernel"

# The Engine's side of an empty-answer retry: a turn the retry answered is an
# ordinary completed turn (the nudge kept, hidden); one whose retries ran out
# ends with TurnNote.empty in place of the nudge.
RSpec.describe Samagotchi::Engine, "#run_turn with an empty-answer retry" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:nudge) { Samagotchi::TurnNote.empty_retry }
  let(:events) { [] }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
  end

  def chat_turn(*steps)
    backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new(*steps))
    allow(engine).to receive(:backend_for).and_return(backend)
    engine.run_turn(session, "hi", on_event: ->(e) { events << e })
  end

  it "keeps the hidden nudge, saves the retried answer and completes the turn" do
    result = chat_turn(FakeChatAdapter.text(""), FakeChatAdapter.text("PONG"))

    expect(result.output).to eq("PONG")
    expect(session.messages.last(3)).to match([a_hash_including(role: "user", content: "hi"), nudge, { role: "model", content: "PONG" }])
    expect(session.last_turn).to include("outcome" => "completed")
    expect(events.map { |e| e[:type] }).to include(:empty_answer_retry, :turn_completed)
    expect(events.count { |e| e[:type] == :generation_started }).to eq(2)
  end

  it "presents the retried answer to after_turn hooks, not the empty one" do
    seen = nil
    engine.instance_variable_get(:@hooks).register(:after_turn) do |event|
      seen = event[:messages]&.last
      nil
    end

    chat_turn(FakeChatAdapter.text(""), FakeChatAdapter.text("PONG"))

    expect(seen).to include(role: "model", content: "PONG")
  end

  it "ends with TurnNote.empty in place of the nudge when the retry is empty too" do
    result = chat_turn(FakeChatAdapter.text(""))
    note = Samagotchi::TurnNote.empty(retries: 1, steps: [{ role: "model", content: "" }] * 2)

    expect(session.messages.last(2)).to match([a_hash_including(role: "user", content: "hi"), note])
    expect(result.conversation.last).to eq(note)
    expect(result.conversation).not_to include(nudge)
  end

  it "leaves a Stop during the retry generation a cancelled turn, the nudge before its cancel note" do
    controller = Samagotchi::CancellationController.new
    adapter = FakeChatAdapter.new(FakeChatAdapter.text(""), lambda { |**|
      controller.cancel!(:user)
      raise Samagotchi::LLM::RequestCancelled.new(:user)
    })
    allow(engine).to receive(:backend_for).and_return(Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter))

    engine.run_turn(session, "hi", on_event: ->(e) { events << e }, cancel_controller: controller)

    expect(session.messages.last(3).map { |m| m[:content].to_s[0, 40] })
      .to eq(["hi", nudge[:content][0, 40], "[SYSTEM: the previous turn was cancelled"])
    expect(session.last_turn).to include("outcome" => "canceled")
    expect(events.map { |e| e[:type] }).to include(:empty_answer_retry, :turn_canceled)
  end
end
