# frozen_string_literal: true

require "samagotchi/system_one"

RSpec.describe Samagotchi::SystemOne::FakeBackend do
  def answer(id, p) = Samagotchi::SystemOne::Answer.new(id: id, type: :noul, noul: p)
  def question(id) = Samagotchi::SystemOne::Question.new(id: id, type: :noul, instructions: "allow #{id}?")

  it "answers from a block that sees the state and the questions" do
    backend = described_class.new do |state, questions|
      questions.to_h { |q| [q.id, answer(q.id, state.include?("push") ? 0.99 : 0.2)] }
    end

    expect(backend.ask(state: "git push origin main", questions: [question("git-push")]).values.map(&:noul)).to eq([0.99])
    expect(backend.ask(state: "rm -rf tmp", questions: [question("rm")]).values.map(&:noul)).to eq([0.2])
    expect(backend.calls).to eq(2)
  end

  it "answers the same from a fixed hash, only for the questions asked" do
    backend = described_class.new({ "git-push" => answer("git-push", 0.97) })
    expect(backend.ask(state: "anything", questions: [question("git-push")]).values.map(&:noul)).to eq([0.97])
    expect(backend.ask(state: "anything", questions: [question("other")])).to eq({})
  end

  it "raises on every call when it is failing" do
    backend = described_class.new(failing: true, error: "the judge is asleep")
    expect(backend).to be_failing
    expect { backend.ask(state: "x", questions: [question("a")]) }
      .to raise_error(Samagotchi::SystemOne::BackendError, "the judge is asleep")
    expect(backend.calls).to eq(1)
  end

  it "says what it is without leaking the answers" do
    expect(described_class.new(failing: true).inspect).to eq("#<Samagotchi::SystemOne::FakeBackend calls=0 failing>")
  end
end
