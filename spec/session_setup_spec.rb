# frozen_string_literal: true

require "spec_helper"
require "samagotchi/session_setup"
require "samagotchi/session"

RSpec.describe Samagotchi::SessionSetup do
  it "is empty with no setting of its own" do
    expect(described_class.new).to be_empty
    expect(described_class.new(llm_context: Samagotchi::LLMContextOverride.new(apply: :turn_end))).not_to be_empty
  end

  it "takes a session's own settings, and none from no session" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    expect(described_class.of(session)).to eq(described_class.new)

    session.llm_context = Samagotchi::LLMContextOverride.new(strategy: [:stale])
    expect(described_class.of(session).llm_context).to eq(Samagotchi::LLMContextOverride.new(strategy: [:stale]))
    expect(described_class.of(nil)).to be_empty
  end

  it "starts a new session with its settings" do
    override = Samagotchi::LLMContextOverride.new(budget_tokens: 0)
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd,
                                              setup: described_class.new(llm_context: override))

    expect(session.llm_context).to eq(override)
  end
end
