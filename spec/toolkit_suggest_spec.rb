# frozen_string_literal: true

require "spec_helper"
require "samagotchi/toolkit_suggest"

RSpec.describe Samagotchi::ToolkitSuggest do
  let(:kits) do
    Samagotchi::Toolkit.kits(config: {
      "web" => { "base" => "lean", "description" => "Browser work" },
      "coding" => { "base" => "child", "description" => "Code changes" },
      "undecided" => { "base" => "lean", "description" => "Must not be offered" },
      "empty" => { "base" => "lean" },
      "review" => { "base" => "lean", "description" => "Must not be offered" }
    })
  end

  it "offers described non-default kits, the default fallback, and undecided" do
    question, = described_class.question(default: Samagotchi::Toolkit.new(name: "full"), kits: kits,
                                         project: "samagotchi", prompt: "Add a feature")

    expect(question.type).to eq(:choice)
    expect(question.instructions).to eq(described_class::INSTRUCTIONS)
    expect(question.criteria).to eq(
      "kit:web" => "web: Browser work",
      "kit:coding" => "coding: Code changes",
      "default" => "none of the other toolkits fits: the user's everyday default",
      "undecided" => "There is no task yet; defer this choice"
    )
  end

  it "limits classifier prompt text and uses only the project name in state" do
    _question, state = described_class.question(default: Samagotchi::Toolkit.new(name: "full"), kits: kits,
                                                project: "samagotchi", prompt: "x" * 1600)

    expect(state).to eq(project: "samagotchi", prompt: "x" * 1500)
  end

  describe ".eligible?" do
    let(:session) do
      Struct.new(:toolkit_origin, :delegate?, :review?, :messages).new(
        "default", false, false, []
      )
    end
    let(:eligible) do
      { session: session, prompt: "Do the work", author: nil, candidate_count: 2,
        last_suggestion: nil, defer_turns: 3, defer_tokens: 5000 }
    end

    it "allows the first prompt of a default, non-delegate, non-review session" do
      expect(described_class.eligible?(**eligible)).to be(true)
    end

    {
      "a chosen toolkit" => ->(args) { args[:session].toolkit_origin = "chosen" },
      "a delegate child" => ->(args) { args[:session].define_singleton_method(:delegate?) { true } },
      "a review session" => ->(args) { args[:session].define_singleton_method(:review?) { true } },
      "a participant turn" => ->(args) { args[:author] = "participant" },
      "a blank prompt" => ->(args) { args[:prompt] = " \n " },
      "fewer than two candidates" => ->(args) { args[:candidate_count] = 1 }
    }.each do |label, mutate|
      it "skips #{label}" do
        args = eligible.dup
        mutate.call(args)
        expect(described_class.eligible?(**args)).to be(false)
      end
    end

    it "allows a later prompt only after undecided and inside both defer bounds" do
      session.messages << { role: "user", turn_id: "one", content: "first" }
      session.messages << { role: "model", content: "reply" }
      args = eligible.merge(last_suggestion: { "raw" => "undecided" })

      expect(described_class.eligible?(**args)).to be(true)
      expect(described_class.eligible?(**args, last_suggestion: { "raw" => "default" })).to be(false)
      expect(described_class.eligible?(**args, defer_turns: 1)).to be(false)
      expect(described_class.eligible?(**args, defer_tokens: 1)).to be(false)
    end

    it "allows an initial turn with an undecided record because no model reply exists yet" do
      session.messages << { role: "user", turn_id: "one", content: "first" }

      expect(described_class.eligible?(**eligible, last_suggestion: { "raw" => "undecided" })).to be(true)
    end
  end

  it "records a normalized suggestion, every offered kit's rules and marks low-confidence picks for mode on" do
    client = instance_double(Samagotchi::SystemOne::Client)
    log = instance_double(Samagotchi::SystemOne::Log)
    web_rules = described_class.rules(Samagotchi::Toolkit.resolve_kit("web", kits))
    full_rules = described_class.rules(Samagotchi::Toolkit.resolve_kit("full", kits))
    candidate = described_class::Candidate.new(name: "web", description: "Browser work", rules: web_rules)
    default = described_class::Candidate.new(name: "full", description: nil, rules: full_rules)
    snapshot = described_class::Snapshot.new(session_id: "s1", turn_number: 1, default: default,
                                             candidates: [candidate], core_tools: %w[read write],
                                             state: { project: "app", prompt: "Fix it" })
    answer = Samagotchi::SystemOne::Answer.new(id: described_class::QUESTION_ID, type: :choice, choice: "kit:web",
                                               confidence: 0.4)
    allow(client).to receive(:ask).and_return(described_class::QUESTION_ID => answer)
    expect(log).to receive(:entry).with("suggestion", hash_including(
      session_id: "s1", turn_number: 1, raw: "kit:web", kit: "web",
      confidence: 0.4, would: "below_threshold", core_tools: %w[read write],
      kits: { "full" => full_rules, "web" => web_rules }
    ))

    suggestion = described_class.ask(client: client, log: log, snapshot: snapshot, threshold: 0.5)

    expect(suggestion).to eq(described_class::Suggestion.new(kit: "web", raw: "kit:web", confidence: 0.4, decided: false))
  end

  it "logs a kit as rules, not a tool list, so tools registered later still resolve" do
    rules = described_class.rules(Samagotchi::Toolkit.resolve_kit("web", kits))

    expect(rules.keys).to eq(%w[all_core core added removed groups])
    expect(rules).to be_frozen
    expect(described_class.rules(Samagotchi::Toolkit.resolve_kit("full", kits))).to include("all_core" => true, "groups" => "all")
  end
end
