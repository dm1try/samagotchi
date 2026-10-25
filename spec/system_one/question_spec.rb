# frozen_string_literal: true

require "samagotchi/system_one/question"

RSpec.describe Samagotchi::SystemOne::Question do
  def question(fields) = described_class.new(**fields)

  it "writes the wire entry each type takes" do
    expect(question(id: "git-push", type: :noul, instructions: "Would the user allow this git push?").to_wire)
      .to eq({ "type" => "noul", "instructions" => "Would the user allow this git push?" })

    choice = question(id: "kind", type: :choice, instructions: "Which kind of call is this?",
                      criteria: { "read" => "reads a file", "write" => nil })
    expect(choice.to_wire).to eq({ "type" => "choice", "instructions" => "Which kind of call is this?",
                                   "criteria" => { "read" => "reads a file", "write" => nil } })

    score = question(id: "risk", type: :score, instructions: "How risky is this?", criteria: %w[none some high])
    expect(score.to_wire).to eq({ "type" => "score", "instructions" => "How risky is this?",
                                  "criteria" => %w[none some high] })
  end

  it "accepts the type as the wire writes it and keeps the id trimmed" do
    q = question(id: "  git-push  ", type: "noul", instructions: " allow? ")
    expect(q).to have_attributes(id: "git-push", type: :noul)
    expect(q.instructions).to eq(" allow? ")
  end

  it "takes criteria only where the contract wants them" do
    expect { question(id: "a", type: :noul, instructions: "x", criteria: %w[yes no]) }
      .to raise_error(ArgumentError, /noul question takes no criteria/)
    expect { question(id: "a", type: :choice, instructions: "x") }
      .to raise_error(ArgumentError, /choice question takes criteria/)
    expect { question(id: "a", type: :score, instructions: "x", criteria: "low|high") }
      .to raise_error(ArgumentError, /score question takes criteria as a list/)
  end

  it "refuses a type, an id or instructions the contract doesn't have" do
    expect { question(id: "a", type: "maybe", instructions: "x") }.to raise_error(ArgumentError, /type must be one of/)
    expect { question(id: "", type: :noul, instructions: "x") }.to raise_error(ArgumentError, /needs an id/)
    expect { question(id: "a", type: :noul, instructions: "   ") }.to raise_error(ArgumentError, /instructions are required/)
  end

  it "coerces a Question as given and a hash with either key style" do
    q = question(id: "a", type: :noul, instructions: "x")
    expect(described_class.coerce("a", q)).to eq(q)
    expect(described_class.coerce("a", { "type" => "noul", "instructions" => "x" })).to eq(q)
    expect(described_class.coerce("a", type: :noul, instructions: "x")).to eq(q)
    expect { described_class.coerce("a", "yes or no") }.to raise_error(ArgumentError, /expected a SystemOne::Question/)
  end
end
