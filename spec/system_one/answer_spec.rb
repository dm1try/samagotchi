# frozen_string_literal: true

require "samagotchi/system_one/answer"

RSpec.describe Samagotchi::SystemOne::Answer do
  def from_wire(raw) = described_class.from_wire("q", raw)

  it "reads a noul answer as a probability" do
    answer = from_wire({ "type" => "noul", "noul" => 0.97 })
    expect(answer).to have_attributes(id: "q", type: :noul, noul: 0.97, choice: nil, score: nil,
                                      confidence: nil, probabilities: nil)
    expect(from_wire({ "type" => "noul", "noul" => 1 }).noul).to eq(1.0)
    expect(from_wire({ "type" => "noul", "noul" => 0 }).noul).to eq(0.0)
  end

  it "reads a choice answer with its confidence and probabilities" do
    answer = from_wire({ "type" => "choice", "choice" => "git-push", "confidence" => 0.91,
                         "probabilities" => { "git-push" => 0.91, "other" => 0.09 } })
    expect(answer).to have_attributes(type: :choice, choice: "git-push", confidence: 0.91,
                                      noul: nil, probabilities: { "git-push" => 0.91, "other" => 0.09 })
  end

  # What POST http://127.0.0.1:8000/v1/systemone answers a two-level score
  # question with (host main, model ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0,
  # state "git push origin main # docs only, one commit", criteria allow/ask),
  # verbatim from the response's answers map.
  REAL_TWO_LEVEL = {
    "type" => "score",
    "score" => 0.06001537920600701,
    "legend" => { "0" => "allow", "1" => "ask" },
    "probabilities" => { "0" => 0.9399846207939929, "1" => 0.06001537920600701 },
    "confidence" => 0.6724940341689145
  }.freeze

  # The same host, criteria safe/moderate/dangerous, asked of the same state.
  REAL_THREE_LEVEL = {
    "type" => "score",
    "score" => 0.03632387287794245,
    "legend" => { "0" => "safe", "1" => "moderate", "2" => "dangerous" },
    "probabilities" => { "0" => 0.9701821968222645, "1" => 0.023311733477528764, "2" => 0.006506069700206843 },
    "confidence" => 0.8636907071300592
  }.freeze

  it "reads a score answer as the weighted level the server sends, named by its legend" do
    answer = from_wire(REAL_TWO_LEVEL)
    expect(answer).to have_attributes(type: :score, level: "allow", confidence: 0.6724940341689145,
                                      probabilities: { "0" => 0.9399846207939929, "1" => 0.06001537920600701 })
    # score is Σ index × its probability, so on two levels it is the
    # probability of level 1 — here, 6% for "ask".
    expect(answer.score).to eq(REAL_TWO_LEVEL["probabilities"].sum { |index, weight| index.to_i * weight })
    expect(answer.score).to eq(0.06001537920600701)

    three = from_wire(REAL_THREE_LEVEL)
    expect(three.level).to eq("safe")
    expect(three.score).to eq(REAL_THREE_LEVEL["probabilities"].sum { |index, weight| index.to_i * weight })
    expect(three.score).to be_between(0, 2)
  end

  it "names the level the probabilities favour, and keeps a whole score whole" do
    expect(from_wire({ "type" => "score", "score" => 2, "confidence" => 0.5, "probabilities" => [0.1, 0.4, 0.5] }))
      .to have_attributes(type: :score, score: 2, level: nil, confidence: 0.5, probabilities: [0.1, 0.4, 0.5])
    expect(from_wire({ "type" => "score", "score" => 1.0 }).score).to eq(1)
    expect(from_wire({ "type" => "score", "score" => 1, "legend" => %w[low mid high],
                       "probabilities" => [0.1, 0.7, 0.2] }))
      .to have_attributes(score: 1, level: "mid")
    # The weighted index can land exactly on a level.
    expect(from_wire({ "type" => "score", "score" => 2.0, "legend" => { "0" => "no", "1" => "maybe", "2" => "yes" },
                       "probabilities" => { "0" => 0.0, "1" => 0.0, "2" => 1.0 } }))
      .to have_attributes(score: 2, level: "yes")
  end

  it "is nil for a score out of the levels, or one that isn't a number" do
    out_of_range = [
      { "type" => "score", "score" => 2.5, "legend" => { "0" => "allow", "1" => "ask" } },
      { "type" => "score", "score" => 1.5, "probabilities" => [0.5, 0.5] },
      { "type" => "score", "score" => "high" },
      { "type" => "score", "score" => -1 },
      { "type" => "score", "score" => Float::NAN },
      { "type" => "score" },
      { "type" => "score", "score" => 0.5, "legend" => {} },
      { "type" => "score", "score" => 0.5, "legend" => { "level one" => "allow" } }
    ]
    expect(out_of_range.map { |raw| from_wire(raw) }.uniq).to eq([nil])
  end

  it "is nil for anything malformed, never a guess" do
    malformed = [
      nil, "noul", 7,
      {},                                  # no type
      { "type" => "maybe", "noul" => 0.5 },   # a type the contract doesn't have
      { "noul" => 0.5 },                     # the type is missing
      { "type" => "noul" },                  # no noul
      { "type" => "noul", "noul" => "0.97" },  # a noul that isn't a number
      { "type" => "noul", "noul" => 1.2 },   # outside 0..1
      { "type" => "noul", "noul" => -0.1 },
      { "type" => "noul", "noul" => Float::NAN },
      { "type" => "choice" },                # no choice
      { "type" => "choice", "choice" => "" },
      { "type" => "score", "score" => "high" },
      { "type" => "score", "score" => -1 },
      { "type" => "noul", "noul" => 0.5, "confidence" => 1.4 },  # a field it can't read
      { "type" => "noul", "noul" => 0.5, "probabilities" => { "a" => "high" } }
    ]
    expect(malformed.map { |raw| from_wire(raw) }.uniq).to eq([nil])
  end

  it "ignores a field the server sends as null" do
    expect(from_wire({ "type" => "noul", "noul" => 0.5, "confidence" => nil, "probabilities" => nil }))
      .to have_attributes(noul: 0.5, confidence: nil, probabilities: nil)
  end

  it "keeps the id the question had" do
    expect(described_class.from_wire("git-push", { "type" => "noul", "noul" => 0.4 }).id).to eq("git-push")
  end
end
