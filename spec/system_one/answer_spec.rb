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

  it "reads a score answer, whole numbers only, and a probabilities list" do
    expect(from_wire({ "type" => "score", "score" => 2, "confidence" => 0.5, "probabilities" => [0.1, 0.4, 0.5] }))
      .to have_attributes(type: :score, score: 2, confidence: 0.5, probabilities: [0.1, 0.4, 0.5])
    expect(from_wire({ "type" => "score", "score" => 1.0 }).score).to eq(1)
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
      { "type" => "score", "score" => 1.5 }, # not a whole level
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
