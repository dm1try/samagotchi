# frozen_string_literal: true

require "spec_helper"
require "samagotchi/answer_text"
require "samagotchi/session_chain"
require "samagotchi/plugin/context"

# What the user saw of an answer: one rule for the continue note's last
# answer, a check's record and a bundle's ctx.last_answer.
RSpec.describe Samagotchi::AnswerText do
  cases = {
    "a closed thought" => ["<think>secret</think>Visible answer", "Visible answer"],
    "a thought cut off before it closed" => ["<think>I should not tell the user about the secret plan", ""],
    "a thought the template opened" => ["secret reasoning</think>Visible answer", "Visible answer"],
    "a Gemma thought" => ["<|channel>thought\nsecret<channel|>Visible answer", "Visible answer"],
    "a Gemma thought cut off" => ["<|channel>thought\nsecret forever", ""],
    "a call's markup" => ["Answer <tool_call>{\"name\":\"x\"}</tool_call>", "Answer"],
    "a chat entry's plain text" => ["Plain **answer**", "Plain **answer**"]
  }

  cases.each do |name, (text, seen)|
    it "takes out #{name}" do
      expect(described_class.visible(text)).to eq(seen)
    end
  end

  it "keeps an answer's start when it quotes a closing tag after a closed thought" do
    expect(described_class.visible("<think>t</think>Use `</think>` there")).to start_with("Use `")
  end

  describe "its callers say the same" do
    let(:ctx) do
      host = Samagotchi::Plugin::Host.new(session_id: -> { "s1" }, messages: -> { messages })
      Samagotchi::Plugin::Context.new(bundle: "b", label: "plugin.rb (bundle b)", settings: {}, host: host)
    end
    let(:messages) { [] }

    cases.each do |name, (text, seen)|
      it "for #{name}: the continue note's last answer and ctx.last_answer" do
        messages.replace([{ role: "user", content: "q", turn_id: "t1" }, { role: "model", content: text }])
        expect(Samagotchi::SessionChain.last_answer(messages)).to eq(seen.empty? ? nil : seen)
        expect(ctx.last_answer).to eq(seen.empty? ? nil : seen)
      end
    end

    it "reads a saved session's string keys, and has nothing with no answer" do
      messages.replace([{ "role" => "user", "content" => "q" }, { "role" => "model", "content" => "<think>t</think>Hi" }])
      expect(ctx.last_answer).to eq("Hi")
      messages.replace([{ role: "user", content: "q" }])
      expect(ctx.last_answer).to be_nil
    end
  end
end
