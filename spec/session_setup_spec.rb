# frozen_string_literal: true

require "spec_helper"
require "samagotchi/session_setup"
require "samagotchi/session"

RSpec.describe Samagotchi::SessionSetup do
  it "is empty with no setting of its own" do
    expect(described_class.new).to be_empty
    expect(described_class.new(llm_context: Samagotchi::LLMContextOverride.new(apply: :turn_end))).not_to be_empty
    expect(described_class.new(thinking: :low)).not_to be_empty
    expect(described_class.new(reasoning_history: :drop)).not_to be_empty
    expect(described_class.new(appended_prompt_files: ["/r/a.md"])).not_to be_empty
    expect(described_class.new(toolkit: Samagotchi::Toolkit.new(name: "lean"))).not_to be_empty
  end

  it "takes a session's own settings, and none from no session" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    # A session without a toolkit (from before them) is on full: its
    # continue and fork too, never config's default.
    expect(described_class.of(session)).to eq(described_class.new(toolkit: Samagotchi::Toolkit.new(name: "full")))
    session.toolkit = Samagotchi::Toolkit.new(name: "lean", remove: ["web_fetch"])
    expect(described_class.of(session).toolkit).to eq(session.toolkit)

    session.llm_context = Samagotchi::LLMContextOverride.new(strategy: [:stale])
    expect(described_class.of(session).llm_context).to eq(Samagotchi::LLMContextOverride.new(strategy: [:stale]))
    session.thinking = :off
    expect(described_class.of(session).thinking).to eq(:off)
    session.reasoning_history = :all
    expect(described_class.of(session).reasoning_history).to eq(:all)
    session.appended_prompt_files = ["/r/a.md"]
    expect(described_class.of(session).appended_prompt_files).to eq(["/r/a.md"])
    expect(described_class.of(nil)).to be_empty
  end

  it "starts a new session with its settings" do
    override = Samagotchi::LLMContextOverride.new(budget_tokens: 0)
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd,
                                              setup: described_class.new(llm_context: override, thinking: :medium,
                                                                         reasoning_history: :drop,
                                                                         appended_prompt_files: ["/r/a.md"]))

    expect(session).to have_attributes(llm_context: override, thinking: :medium, reasoning_history: :drop,
                                       appended_prompt_files: ["/r/a.md"])
  end
end
