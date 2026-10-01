# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require_relative "support/fake_chat_adapter"
require "support/test_kernel"

# --no-interrupt raises a turn's iteration limit to 1000 for whichever loop
# runs it: the Engine hands the backend the limit (as the worker does).
RSpec.describe Samagotchi::Engine, "with no_interrupt" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
  end

  # The max_iterations the chat backend was asked to run with.
  def limit_for(no_interrupt:, **turn_options)
    engine = described_class.new(client: client, kernel: kernel, profile: "gemma4", no_interrupt: no_interrupt)
    backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new(FakeChatAdapter.text("ok")))
    allow(engine).to receive(:backend_for).and_return(backend)
    seen = nil
    allow(backend).to receive(:complete).and_wrap_original do |original, **options|
      seen = options[:max_iterations]
      original.call(**options)
    end
    engine.run_turn(session, "hi", **turn_options)
    seen
  end

  it "runs a chat host's turn with 1000 iterations" do
    expect(limit_for(no_interrupt: true)).to eq(1000)
  end

  it "keeps the turn's own limit without it" do
    expect(limit_for(no_interrupt: false)).to eq(100)
    expect(limit_for(no_interrupt: false, max_iterations: 7)).to eq(7)
  end
end
