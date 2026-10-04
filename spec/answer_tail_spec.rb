# frozen_string_literal: true

require "spec_helper"
require "samagotchi/answer_tail"
require "samagotchi/web/app"

RSpec.describe Samagotchi::AnswerTail do
  let(:app) do
    Samagotchi::Web::App.new(manager: Object.new, state_dir: Dir.mktmpdir, markdown: false, bridge_wait_timeout: 0)
  end

  # The web's walk before AnswerTail: the last message messages_for_display
  # shows as an assistant message.
  def old_walk(msgs)
    Array(msgs).reverse_each do |m|
      shown = app.send(:messages_for_display, [m]).first
      return [shown] if shown && shown[:role] == "assistant"
    end
    []
  end

  def new_walk(msgs)
    app.send(:messages_for_display, [described_class.find(msgs)].compact)
  end

  def stringify(msgs) = JSON.parse(JSON.generate(msgs))

  fixtures = {
    "a plain answer" => [{ role: "user", content: "q" }, { role: "assistant", content: "the answer" }],
    "model role" => [{ role: "user", content: "q" }, { role: "model", content: "a gemma answer" }],
    "a context note after the answer" => [
      { role: "user", content: "q" }, { role: "assistant", content: "the answer" },
      Samagotchi::ContextNote.message(note_id: "n1", text: "deploy frozen", source: "slack")
    ],
    "a note marked on an assistant message" => [
      { role: "assistant", content: "earlier" }, { role: "assistant", kind: "note", content: "a note" }
    ],
    "a steer after the answer" => [
      { role: "user", content: "q" }, { role: "assistant", content: "the answer" },
      Samagotchi::Steer.message(text: "keep going", source: "check-in")
    ],
    "a steer marked on an assistant message" => [
      { role: "assistant", content: "earlier" }, { role: "assistant", kind: "steer", content: "s" }
    ],
    "an empty-answer marker" => [
      { role: "user", content: "q1" }, { role: "assistant", content: "first" },
      { role: "user", content: "q2" }, Samagotchi::TurnNote.empty(retries: 1)
    ],
    "an empty-answer marker on an assistant message" => [
      { role: "assistant", content: "earlier" },
      Samagotchi::TurnNote.empty(retries: 0).merge(role: "assistant", content: "x")
    ],
    "a display" => [{ role: "user", content: "q" }, { role: "assistant", content: "a JIRA-1", display: "a [JIRA-1](https://j.test)" }],
    "a tool-call-only step last" => [
      { role: "user", content: "q" }, { role: "assistant", content: "the answer" },
      { role: "assistant", content: "", tool_calls: [{ id: "c1" }] }, { role: "tool_response", content: "out" }
    ],
    "markup-only content" => [
      { role: "assistant", content: "the answer" }, { role: "assistant", content: "<|turn><|think|>" }
    ],
    "a system message last" => [{ role: "assistant", content: "the answer" }, { role: "system", content: "reminder" }],
    "a user message last" => [{ role: "assistant", content: "the answer" }, { role: "user", content: "next" }],
    "no answer at all" => [{ role: "user", content: "q" }],
    "empty" => [],
    "nil" => nil
  }

  # The content each fixture's answer has (nil: no answer).
  shown = {
    "a plain answer" => "the answer", "model role" => "a gemma answer", "a context note after the answer" => "the answer",
    "a note marked on an assistant message" => "earlier", "a steer after the answer" => "the answer",
    "a steer marked on an assistant message" => "earlier", "an empty-answer marker" => "first",
    "an empty-answer marker on an assistant message" => "earlier", "a display" => "a JIRA-1",
    "a tool-call-only step last" => "the answer", "markup-only content" => "the answer",
    "a system message last" => "the answer", "a user message last" => "the answer"
  }

  fixtures.each do |name, msgs|
    it "finds the answer today's walk shows: #{name} (symbol and string keys)" do
      [msgs, msgs && stringify(msgs)].each do |list|
        expect(new_walk(list)).to eq(old_walk(list))
        expect(new_walk(list).map { |m| m[:content] }).to eq([shown[name]].compact)
      end
    end
  end

  describe "turn_id:" do
    msgs = [
      { role: "user", content: "first", turn_id: "tA" },
      { role: "assistant", content: "", tool_calls: [{ id: "c" }] },
      { role: "assistant", content: "answer A" },
      { role: "user", content: "steering", kind: "input" },
      { role: "assistant", content: "answer A, steered" },
      { role: "user", content: "a steer", kind: "steer" },
      { role: "user", content: "second", turn_id: "tB" },
      { role: "assistant", content: "answer B" },
      { role: "user", content: "third", turn_id: "tC" }
    ]

    it "is that turn's last answer (merged input and steers are the turn's); symbol and string keys" do
      [msgs, stringify(msgs)].each do |list|
        found = ->(id) { described_class.find(list, turn_id: id).then { |m| m && (m[:content] || m["content"]) } }
        expect(found.call("tA")).to eq("answer A, steered")
        expect(found.call("tB")).to eq("answer B")
        # A turn with no answer (yet): none, not an earlier turn's.
        expect(found.call("tC")).to be_nil
      end
    end

    it "an unknown, empty or nil id: the newest answer" do
      ["nope", "", nil].each { |id| expect(described_class.find(msgs, turn_id: id)[:content]).to eq("answer B") }
    end
  end

  it "returns the raw message itself, not a copy" do
    answer = { role: "assistant", content: "the answer" }
    expect(described_class.find([{ role: "user", content: "q" }, answer])).to equal(answer)
  end

  # The one deliberate difference: a render that raises makes
  # messages_for_display return [] (its rescue). The old walk then went on to
  # an earlier answer; now the reply has no answer.
  it "a message whose render raises: no answer (the old walk took an earlier one)" do
    msgs = [{ role: "assistant", content: "earlier" }, { role: "assistant", content: "boom" }]
    allow(app.instance_variable_get(:@markdown_renderer)).to receive(:available?).and_return(true)
    allow(app.instance_variable_get(:@markdown_renderer)).to receive(:render) do |text|
      raise "render failed" if text == "boom"

      "<p>#{text}</p>"
    end

    expect(old_walk(msgs).map { |m| m[:content] }).to eq(["earlier"])
    expect(new_walk(msgs)).to eq([])
  end
end
