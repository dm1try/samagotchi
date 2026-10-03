# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "support/test_kernel"

# The Bridge's GET tail reads one message, never the whole conversation.
RSpec.describe Samagotchi::Engine, "#last_answer_message" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:engine) { described_class.new(client: client, kernel: test_kernel(client: client)) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }

  before { engine.session = session }

  it "is a copy of the last answer shown, without a checkpoint of the conversation" do
    answer = { role: "assistant", content: "the answer" }
    session.messages = [{ role: "user", content: "q" }, answer, { role: "assistant", content: "", tool_calls: [{ id: "c" }] }]
    expect(engine).not_to receive(:messages_checkpoint)
    expect(engine).not_to receive(:clone_messages)

    found = engine.last_answer_message

    expect(found).to eq(answer)
    expect(found).not_to equal(answer)
  end

  it "is nil with no answer, or no session" do
    session.messages = [{ role: "user", content: "q" }]
    expect(engine.last_answer_message).to be_nil
    expect(described_class.new(client: client, kernel: test_kernel(client: client)).last_answer_message).to be_nil
  end
end
