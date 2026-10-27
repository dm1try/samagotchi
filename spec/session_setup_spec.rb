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
    expect(described_class.new(toolkit: Samagotchi::Toolkit.new(name: "lean")).toolkit_origin).to eq("chosen")
    expect(described_class.new(toolkit_origin: "chosen")).not_to be_empty
    expect(described_class.new(settings: Samagotchi::SessionConfig::Settings.new(bundles: { "cost-cap" => { "cap" => 3 } }))).not_to be_empty
    expect(described_class.new(settings: Samagotchi::SessionConfig::Settings.new(bundles: {}))).to be_empty
    expect(described_class.new(parent_answers: "hard")).not_to be_empty
    expect(described_class.new(working_set_pins: [{ "kind" => "file", "key" => "/r/a.rb" }])).not_to be_empty
  end

  it "keeps bundle settings frozen, string-keyed" do
    setup = described_class.new(settings: Samagotchi::SessionConfig::Settings.new(bundles: { "cost-cap": { cap: 3 } }))
    expect(setup.settings.bundles).to eq("cost-cap" => { "cap" => 3 })
    expect(setup.settings.bundles).to be_frozen
    expect(described_class.new.settings.bundles).to eq({})
  end

  it "takes a session's own settings, and none from no session" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    # A session without a toolkit (from before them) is on full: its
    # continue and fork too, never config's default.
    expect(described_class.of(session)).to eq(described_class.new(toolkit: Samagotchi::Toolkit.new(name: "full"),
                                                                  toolkit_origin: "inherited"))
    session.toolkit = Samagotchi::Toolkit.new(name: "lean", remove: ["web_fetch"])
    expect(described_class.of(session).toolkit).to eq(session.toolkit)
    expect(described_class.of(session).toolkit_origin).to eq("inherited")

    session.llm_context = Samagotchi::LLMContextOverride.new(strategy: [:stale])
    expect(described_class.of(session).llm_context).to eq(Samagotchi::LLMContextOverride.new(strategy: [:stale]))
    session.thinking = :off
    expect(described_class.of(session).thinking).to eq(:off)
    session.reasoning_history = :all
    expect(described_class.of(session).reasoning_history).to eq(:all)
    session.appended_prompt_files = ["/r/a.md"]
    expect(described_class.of(session).appended_prompt_files).to eq(["/r/a.md"])
    session.settings = Samagotchi::SessionConfig::Settings.new(core: { "recap.enabled" => false }, bundles: { "cost-cap" => { "cap" => 2 } })
    expect(described_class.of(session).settings.bundles).to eq("cost-cap" => { "cap" => 2 })
    expect(described_class.of(session).settings.core).to eq("recap.enabled" => false)
    session.parent_answers = "standard"
    expect(described_class.of(session).parent_answers).to eq("standard")
    session.working_set_pins = [{ "kind" => "file", "key" => "/r/a.rb" }]
    expect(described_class.of(session).working_set_pins).to eq([Samagotchi::WorkingSetPin.new(kind: "file", key: "/r/a.rb")])
    expect(described_class.of(nil)).to be_empty
  end

  it "starts a new session with its settings" do
    override = Samagotchi::LLMContextOverride.new(budget_tokens: 0)
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd,
                                              setup: described_class.new(llm_context: override, thinking: :medium,
                                                                         reasoning_history: :drop,
                                                                         appended_prompt_files: ["/r/a.md"],
                                                                         settings: Samagotchi::SessionConfig::Settings.new(bundles: { "x" => { "k" => 1 } }),
                                                                         parent_answers: "hard",
                                                                         working_set_pins: [{ kind: "memory", key: "notes" }]))

    expect(session).to have_attributes(llm_context: override, thinking: :medium, reasoning_history: :drop,
                                       appended_prompt_files: ["/r/a.md"], settings: Samagotchi::SessionConfig::Settings.new(bundles: { "x" => { "k" => 1 } }),
                                       parent_answers: "hard",
                                       working_set_pins: [Samagotchi::WorkingSetPin.new(kind: "memory", key: "notes")])
  end

  it "reads pins from a file's form, leaving out repeats and entries without a kind or key" do
    pins = Samagotchi::WorkingSetPin.list([{ "kind" => "file", "key" => "/r/a.rb" }, { kind: "file", key: "/r/a.rb" },
                                           { "kind" => "url" }, "junk", Samagotchi::WorkingSetPin.new(kind: "url", key: "https://x")])
    expect(pins.map(&:to_file)).to eq([{ "kind" => "file", "key" => "/r/a.rb" }, { "kind" => "url", "key" => "https://x" }])
    expect(pins).to be_frozen
  end
end
