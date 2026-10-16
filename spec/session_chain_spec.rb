# frozen_string_literal: true

require "spec_helper"
require "samagotchi/session_chain"
require "samagotchi/context_note"

# SessionChain.opener_for: the text web `continue →` prefills, derived from the chain.
RSpec.describe Samagotchi::SessionChain, ".opener_for" do
  def link(messages, continues: "11111111-2222-3333-4444-555555555555")
    Samagotchi::Session.new_session(mode: "assist", model_name: "main:m", working_directory: "/tmp").tap do |s|
      s.continues = continues
      s.messages = messages
    end
  end

  let(:note) do
    Samagotchi::ContextNote.message(note_id: "n1", text: "This session continues 11111111 …", source: described_class::NOTE_SOURCE)
  end
  let(:opener) { "You are the coordinator again: read the hand-off memory, check the queue, then list today's merges in order." }

  it "is nil for a chain's first link: its first message is the task, not an opener" do
    expect(described_class.opener_for(link([{ role: "user", content: "fix X", turn_id: "t1" }], continues: nil))).to be_nil
  end

  it "is a link's first typed message, in full (longer than the 80-char preview) and stripped" do
    messages = [{ role: "system", content: "prompt" }, note,
                { role: "user", content: "  #{opener}\n", turn_id: "t1" }, { role: "assistant", content: "ok" },
                { role: "user", content: "later", turn_id: "t2" }]
    expect(opener.length).to be > 80
    expect(described_class.opener_for(link(messages))).to eq(opener)
  end

  it "is nil for a link with only the chain's note (continued before its first turn)" do
    expect(described_class.opener_for(link([note]))).to be_nil
  end

  it "skips a !shell line stored before the typed opener" do
    messages = [note, { role: "user", content: "!(ls)\nREADME.md" }, { role: "user", content: opener, turn_id: "t1" }]
    expect(described_class.opener_for(link(messages))).to eq(opener)
  end

  it "takes a checkpointed prompt without a turn_id, and skips messages with a kind or no text" do
    messages = [{ role: "user", kind: "steer", content: "a steer", turn_id: "t0" },
                { role: "user", content: [{ type: "text", text: "parts" }] }, { role: "user", content: "  " },
                { role: "user", content: opener }]
    expect(described_class.opener_for(link(messages))).to eq(opener)
  end
end
