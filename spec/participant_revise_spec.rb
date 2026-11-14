# frozen_string_literal: true

require "spec_helper"
require "json"
require "samagotchi/participant_revise"
require "samagotchi/participant_messages"
require "samagotchi/revise_anchor"

RSpec.describe Samagotchi::ParticipantRevise do
  let(:alex) { "p:alex" }
  let(:authors) { { "me" => alex, "other" => "p:bea", "owner" => nil } }

  def prompt(turn_id, author = nil, **extra)
    { role: "user", content: "q #{turn_id}", turn_id: turn_id, **(author ? { author: author } : {}), **extra }
  end

  def answer(text = "an answer") = { role: "assistant", content: text }

  def refusal(messages, turn_id, author = alex, **opts)
    described_class.refusal(messages, turn_id: turn_id, author: author, **opts)
  end

  # The shared table (spec/shared/participant_revise_cases.json), also the
  # page mirror's (participant_revise.test.js).
  cases = JSON.parse(File.read(File.expand_path("shared/participant_revise_cases.json", __dir__)))["cases"]

  def history(turns)
    turns.each_with_index.flat_map do |turn, i|
      id = "t#{i}"
      opening = case turn["by"]
                when "shell" then next [{ role: "user", content: "!(ls)\nfile" }]
                when "wake" then { role: "system", content: "note", turn_start: true, turn_id: id }
                else prompt(id, authors.fetch(turn["by"]))
                end
      opening[:verify] = { turn_id: "123e4567-e89b-12d3-a456-426614174000", quote: "claim" } if turn["verify"]
      turn.fetch("answered", true) ? [opening, answer] : [opening]
    end
  end

  cases.each do |c|
    it "#{c["name"]}: #{c["expected"] ? "revisable" : c["reason"]}" do
      expected = c["expected"] ? nil : c["reason"].to_sym
      expect(refusal(history(c["turns"]), "t#{c["target"]}")).to eq(expected)
    end
  end

  it "reads string keys as the Bridge snapshot has them" do
    messages = [{ "role" => "user", "content" => "q", "turn_id" => "a1", "author" => alex },
                { "role" => "assistant", "content" => "a" }]
    expect(refusal(messages, "a1")).to be_nil
  end

  it "answers an id no turn carries as someone else's (no existence oracle)" do
    messages = [prompt("o1"), answer]
    expect(refusal(messages, "nope")).to eq(:not_own)
    expect(refusal(messages, "nope")).to eq(refusal(messages, "o1"))
  end

  it "refuses an owner's author or none as not_own" do
    messages = [prompt("o1"), answer]
    expect(refusal(messages, "o1", nil)).to eq(:not_own)
    expect(refusal(messages, "o1", "owner")).to eq(:not_own)
  end

  it "takes a well-formed Verify claim and the display's verify: true alike, a malformed one as no Verify turn (VerifyAnchor.marks?)" do
    claim = { turn_id: "123e4567-e89b-12d3-a456-426614174000", quote: "the claim" }
    expect(refusal([prompt("a1", alex, verify: claim), answer], "a1")).to eq(:not_own)
    expect(refusal([prompt("a1", alex, verify: true), answer], "a1")).to eq(:not_own)
    expect(refusal([prompt("a1", alex, verify: { turn_id: "x", quote: "q" }), answer], "a1")).to be_nil
    expect(Samagotchi::VerifyAnchor.marks?({ turn_id: "x", quote: "q" })).to be(false)
  end

  it "ignores the Revise turn itself and what follows it with before:" do
    messages = [prompt("a1", alex), answer, prompt("r1", alex), answer, prompt("o1"), answer]
    expect(refusal(messages, "a1", before: "r1")).to be_nil
    expect(refusal(messages, "a1")).to eq(:overtaken)
  end

  it "owns its refusal words and the worker feature" do
    expect(Samagotchi::ParticipantMessages::REVISE_NOT_OWN).to eq("you can revise only an answer to your own message")
    expect(Samagotchi::ParticipantMessages::REVISE_OVERTAKEN).to include("someone else's turn came after this answer")
    expect(Samagotchi::ParticipantMessages::REVISE_UNAVAILABLE).to include("too old for you to revise")
    expect(Samagotchi::ReviseAnchor::PARTICIPANT_FEATURE).to eq("participant_revise")
  end
end
