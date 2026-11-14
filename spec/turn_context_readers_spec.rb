# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/llm_context_override"
require "support/test_kernel"

# The Engine's cross-thread readers of the running turn (W8, arch P3.1): each
# reads the TurnContext TurnState publishes with the running flag, so a thread
# off the turn sees the new turn from its first moment, never the last one's.
# A reader thread runs right where the turn is published (TurnState#begin!),
# before anything else of the turn: the turn thread waits for it (join), so
# the read always lands there.
RSpec.describe Samagotchi::Engine, "cross-thread readers of the running turn" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:first) { { client_id: "participant:p_a", enqueued_id: "e1", author: "p:p_a" } }
  let(:second) { { client_id: "participant:p_b", enqueued_id: "e2", author: "p:p_b" } }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(client).to receive(:complete).and_return("done")
  end

  # Runs a turn whose reader thread reads (the block) the moment the turn is
  # published; returns what it read.
  def read_as_published(origin: Samagotchi::TurnOrigin::NONE, &reader)
    state = engine.send(:turn_state)
    seen = []
    allow(state).to receive(:begin!).and_wrap_original do |original, **kwargs|
      original.call(**kwargs)
      join!(Thread.new { seen << yield }, "the reader thread")
    end
    engine.run_turn(session, "next", origin: origin)
    seen.first
  end

  it "turn_author (ctx.turn_author, the hooks' author, ObjectivesCheck) is the new turn's" do
    engine.run_turn(session, "first", origin: first)

    expect(read_as_published(origin: second) { engine.turn_author }).to eq("p:p_b")
  end

  it "side_author (a plugin's ask_model in the turn) is the new turn's" do
    engine.run_turn(session, "first", origin: first)

    expect(read_as_published(origin: second) { engine.side_author("ask") }).to eq("p:p_b")
  end

  it "working_set_strategy (/working-set's anytime list) is the last turn's until the new one has settings" do
    session.llm_context = Samagotchi::LLMContextOverride.new(strategy: [:forget])
    engine.run_turn(session, "first")
    last = engine.working_set_strategy
    session.llm_context = nil

    expect(last).not_to eq(Samagotchi::LLMContextView::NONE)
    expect(read_as_published { engine.working_set_strategy }).to eq(last)
  end

  it "live_conversation (/objectives, QuestionAsked) is none of the last turn's" do
    engine.run_turn(session, "first")
    expect(kernel.llm_context_turn&.conversation).to be_an(Array)

    expect(read_as_published { engine.live_conversation }).to be_nil
  end
end
