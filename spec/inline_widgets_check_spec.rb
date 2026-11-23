# frozen_string_literal: true

require "spec_helper"
require "samagotchi/inline_widgets"

# InlineWidgets.check: a script's data (a page's walk) through the same schema
# as a ```chi-ui block's YAML, so the same widget draws either.
RSpec.describe Samagotchi::InlineWidgets, ".check" do
  def check(type, data) = described_class.check(type, data)

  let(:walk_yaml) do
    <<~YAML
      type: walk
      title: A tab reconnects
      actors: [user, web]
      steps:
        - id: 1
          actor: user
          does: opens the tab
          next: 2
        - id: 2
          actor: web
          sees: the replay
          behind: Bridge replays from the cursor
          cases:
            - when: the cursor is gone
              goto: 1
    YAML
  end

  let(:walk_symbols) do
    { title: "A tab reconnects", actors: %i[user web],
      steps: [{ id: 1, actor: :user, does: "opens the tab", next: 2 },
              { id: 2, actor: "web", sees: "the replay", behind: "Bridge replays from the cursor",
                cases: [{ when: "the cursor is gone", goto: 1 }] }] }
  end

  let(:walk_strings) do
    { "title" => "A tab reconnects", "actors" => %w[user web],
      "steps" => [{ "id" => "1", "actor" => "user", "does" => "opens the tab", "next" => "2" },
                  { "id" => "2", "actor" => "web", "sees" => "the replay", "behind" => "Bridge replays from the cursor",
                    "cases" => [{ "when" => "the cursor is gone", "goto" => "1" }] }] }
  end

  it "gives a symbol-keyed walk the data parse gives the same walk in YAML" do
    from_yaml = described_class.parse(walk_yaml)
    expect(from_yaml).to be_ok

    result = check("walk", walk_symbols)
    expect(result).to be_ok
    expect(result.type).to eq("walk")
    expect(result.data).to eq(from_yaml.data)
    expect(result).not_to be_lenient
  end

  it "gives a string-keyed walk the same data" do
    expect(check("walk", walk_strings).data).to eq(described_class.parse(walk_yaml).data)
  end

  it "takes the type as a symbol" do
    expect(check(:walk, walk_strings)).to be_ok
  end

  it "keeps nil as absent, as YAML's empty value" do
    data = walk_strings.merge("steps" => [walk_strings["steps"][0].merge("behind" => nil), walk_strings["steps"][1]])
    expect(check("walk", data).data["steps"][0]).not_to have_key("behind")
  end

  it "makes a number text, as YAML's scalars are" do
    data = walk_strings.merge("title" => 42)
    expect(check("walk", data).data["title"]).to eq("42")
  end

  it "refuses true, false and other values with the path to them" do
    data = walk_strings.merge("steps" => [walk_strings["steps"][0], walk_strings["steps"][1].merge("sees" => true)])
    result = check("walk", data)
    expect(result).not_to be_ok
    expect(result.type).to eq("walk")
    expect(result.error).to eq("steps[1].sees must be text, not true")

    expect(check("walk", walk_strings.merge("title" => Object.new)).error).to start_with("title must be text, not ")
    expect(check("walk", walk_strings.merge(Object.new => "x")).error).to eq("the data has a key that isn't text")
  end

  it "refuses data that isn't a mapping" do
    expect(check("walk", [true]).error).to eq("the data isn't a mapping")
  end

  it "scrubs a string that isn't valid UTF-8" do
    result = check("walk", walk_strings.merge("title" => "bad \xFF byte".b))
    expect(result.data["title"]).to eq("bad \uFFFD byte")
  end

  it "refuses an unknown type, naming no type" do
    result = check("table", walk_strings)
    expect(result.error).to eq('the data\'s type "table" isn\'t picks or walk')
    expect(result.type).to be_nil
  end

  it "refuses data that nests past MAX_DEPTH" do
    deep = (1..described_class::MAX_DEPTH).reduce("x") { |inner, _| { "a" => inner } }
    expect(check("walk", walk_strings.merge("extra" => deep)).error).to eq("the data nests too deep")
  end

  it "refuses a Hash that holds itself, and an Array" do
    loop_hash = walk_strings.dup
    loop_hash["self"] = loop_hash
    expect(check("walk", loop_hash).error).to eq("the data nests too deep")

    list = []
    list << list
    expect(check("walk", walk_strings.merge("actors" => list)).error).to eq("the data nests too deep")
  end

  it "reuses the schema's caps and messages" do
    steps = (1..31).map { |n| { "id" => n.to_s, "actor" => "user", "does" => "x" } }
    expect(check("walk", walk_strings.merge("steps" => steps)).error).to eq("walk has 31 steps (at most 30)")
    expect(check("walk", walk_strings.merge("actors" => ["user"])).error).to eq("walk has 1 actors (2-5)")
    expect(check("walk", walk_strings.merge("title" => "x" * 301)).error).to eq("the title is over 300 characters")
  end

  it "mends a picks id that leads with ! or / without marking the result lenient" do
    result = check("picks", { rows: [{ id: "!1", text: "Drop it?", options: %w[yes no] }] })
    expect(result).to be_ok
    expect(result.data["rows"][0]["id"]).to eq("1")
    expect(result).not_to be_lenient
  end
end
