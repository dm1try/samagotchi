# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/objectives"

RSpec.describe Samagotchi::Objectives do
  let(:list) do
    described_class::List.new.set([{ text: "Two coffees, open the cart" },
                                   { text: "Stops before checkout", done_when: "no order is placed" }])
  end

  def note(id, list)
    Samagotchi::ContextNote.message(note_id: id, text: list.text, source: described_class::SOURCE,
                                    header: Samagotchi::ContextNote::OBJECTIVES_HEADER, objectives: list.to_payload)
  end

  describe "List" do
    it "numbers from O1 and renders what the frame holds" do
      expect(list.text).to eq("O1 Two coffees, open the cart\nO2 Stops before checkout (done when: no order is placed)")
    end

    it "never reuses an id: not after a drop, not after a set" do
      dropped = list.mark("O2", described_class::DROPPED)

      expect(dropped.add("Third").items.last.id).to eq("O3")
      expect(dropped.set([{ text: "New start" }]).items.map(&:id)).to eq(["O3"])
    end

    it "marks by id, and the rendered text says done and leaves dropped out" do
      marked = list.add("Third").mark("O1", described_class::DONE).mark("O3", described_class::DROPPED)

      expect(marked.items.map(&:status)).to eq(%w[done active dropped])
      expect(marked.text).to eq("O1 [done] Two coffees, open the cart\nO2 Stops before checkout (done when: no order is placed)")
    end

    it "says so when nothing is left to send" do
      expect(list.mark("O1", described_class::DROPPED).mark("O2", described_class::DROPPED).text).to eq(described_class::NONE_LEFT)
    end

    it "is not empty once anything was set, a dropped one too" do
      expect(described_class::List.new).to be_empty
      expect(list.mark("O1", described_class::DROPPED)).not_to be_empty
    end

    it "keeps its payload in string keys, the same before a save and after one" do
      payload = list.to_payload

      expect(JSON.parse(JSON.generate(payload))).to eq(payload)
      expect(payload).to eq("next" => 3, "items" => [
        { "id" => "O1", "text" => "Two coffees, open the cart", "status" => "active" },
        { "id" => "O2", "text" => "Stops before checkout", "status" => "active",
          "done_when" => "no order is placed" }
      ])
    end
  end

  describe ".from_payload" do
    it "reads a payload back, in either key style" do
      symbols = { next: 3, items: [{ id: "O2", text: "x", status: "done", done_when: "y" }] }

      expect(described_class.from_payload(symbols)).to eq(described_class.from_payload(JSON.parse(JSON.generate(symbols))))
      expect(described_class.from_payload(symbols).items.first).to have_attributes(id: "O2", status: "done", done_when: "y")
    end

    it "skips what isn't an item, and an id past +next+ moves it on" do
      read = described_class.from_payload("next" => 1, "items" => ["junk", { "text" => "no id" },
                                                                   { "id" => "O7", "text" => "kept", "status" => "weird" }])

      expect(read.items.map(&:id)).to eq(["O7"])
      expect(read.items.first.status).to eq("active")
      expect(read.add("next").items.last.id).to eq("O8")
    end

    it "is nil for what is not a list" do
      [nil, "O1 x", {}, { "next" => 2 }, { "items" => [] }, { "next" => "9", "items" => [] },
       { "next" => 2, "items" => "O1 x" }, { "next" => nil, "items" => [] }].each do |payload|
        expect(described_class.from_payload(payload)).to be_nil
      end
    end

    it "reads item fields of the wrong type as text, so nothing later raises" do
      read = described_class.from_payload("next" => 2, "items" => [{ "id" => "O1", "text" => 7, "done_when" => 8 }])

      expect(read.text).to eq("O1 7 (done when: 8)")
    end
  end

  describe ".build" do
    it "is empty for a conversation with no list, plain notes included" do
      plain = Samagotchi::ContextNote.message(note_id: "n1", text: "deploy frozen", source: "slack")

      expect(described_class.build([{ role: "user", content: "hi" }, plain])).to be_empty
      expect(described_class.build(nil)).to be_empty
    end

    it "takes the newest list note, whatever comes after it" do
      newer = list.add("Third")
      conversation = [note("n1", list), { role: "user", content: "go" }, note("n2", newer), { role: "model", content: "ok" }]

      expect(described_class.build(conversation)).to eq(newer)
    end

    it "reads a conversation as a load has it: its payload in strings" do
      saved = JSON.parse(JSON.generate([note("n1", list)])).map { |m| m.transform_keys(&:to_sym) }

      expect(described_class.build(saved)).to eq(list)
    end

    it "isn't wiped by a malformed list note, and its ids go on" do
      bad = Samagotchi::ContextNote.message(note_id: "n2", text: "x", source: described_class::SOURCE, objectives: {})

      expect(described_class.build([note("n1", list), bad])).to eq(list)
      expect(described_class.build([note("n1", list)], pending: {})).to eq(list)
    end

    it "takes the pending payload over the conversation: it is newer" do
      newer = list.add("Third")

      expect(described_class.build([note("n1", list)], pending: newer.to_payload)).to eq(newer)
    end
  end

  describe "a session's list" do
    let(:tmpdir) { Dir.mktmpdir("objectives") }
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap { |s| s.save(state_dir: tmpdir) }
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }

    after { FileUtils.rm_rf(tmpdir) }

    def queue(list)
      Samagotchi::SessionInbox.write_note(session.id, text: list.text, source: described_class::SOURCE,
                                                      objectives: list.to_payload, state_dir: tmpdir)
    end

    it "finds the newest objectives file among the pending notes, a plain note after it or not" do
      queue(list)
      newer = list.add("Third")
      queue(newer)
      Samagotchi::SessionInbox.write_note(session.id, text: "deploy frozen", state_dir: tmpdir)

      expect(described_class.pending_payload(session_dir)).to eq(newer.to_payload)
    end

    it "looks past a malformed newest file to the pending list before it" do
      queue(list)
      Samagotchi::SessionInbox.write_note(session.id, text: "x", source: described_class::SOURCE, objectives: {}, state_dir: tmpdir)

      expect(described_class.pending_payload(session_dir)).to eq(list.to_payload)
    end

    it "finds none in a session with plain notes only" do
      Samagotchi::SessionInbox.write_note(session.id, text: "deploy frozen", state_dir: tmpdir)

      expect(described_class.pending_payload(session_dir)).to be_nil
    end

    it ".current folds the conversation and the pending file" do
      expect(described_class.current(session.id, [note("n1", list)], state_dir: tmpdir)).to eq(list)

      newer = list.add("Third")
      queue(newer)
      expect(described_class.current(session.id, [note("n1", list)], state_dir: tmpdir)).to eq(newer)
    end
  end
end
