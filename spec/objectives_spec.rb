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

  describe ".build, moves" do
    def recorded(id) = "[objectives]\nRecorded a move on #{id}. The list is unchanged."

    def chat_model(*calls) = { role: "model", content: "", tool_calls: calls }
    def chat_call(id, args) = { id: id, name: "objectives", arguments: args }

    def chat_result(id, ref, text = recorded("O1"))
      { role: "tool_response", content: text, tool_call_id: id, tool_ids: [ref] }
    end

    def built(*entries, **opts) = described_class.build([note("n1", list), *entries], **opts)

    it "reads a chat host's calls, the latest per objective" do
      built_list = built(chat_model(chat_call("a", { action: "move", id: "O2", note: "first" })), chat_result("a", "t1", recorded("O2")),
                         chat_model(chat_call("b", { action: "move", id: "O2", note: "second", evidence: "abc123" })),
                         chat_result("b", "t2", recorded("O2")))

      move = built_list.moves.fetch("O2")
      expect(move).to have_attributes(id: "O2", note: "second", evidence: "abc123")
      expect(move.line).to eq("second (evidence: abc123)")
      expect(built_list.moves).not_to have_key("O1")
    end

    it "reads a kernel host's calls from the model text" do
      text = "<tool_call>\n<function=objectives>\n<parameter=action>\nmove\n</parameter>\n<parameter=id>\nO1\n</parameter>\n" \
             "<parameter=note>\nnative\n</parameter>\n</function>\n</tool_call>"
      built_list = built({ role: "model", content: text }, { role: "tool_response", content: recorded("O1"), tool_ids: ["t1"] })

      expect(built_list.moves.fetch("O1").note).to eq("native")
    end

    it "reads a call_tool's move, as it ran" do
      call = { id: "a", name: "call_tool",
               arguments: { tool: "chi/objectives", args: { action: "move", id: "O1", note: "by the index" } } }
      built_list = built(chat_model(call), chat_result("a", "t1"))

      expect(built_list.moves.fetch("O1").note).to eq("by the index")
    end

    it "leaves out a refused, denied or interrupted call, as the runner saves them" do
      ["[objectives]\nError: no objective O1 (this session's: O2). Nothing was recorded.",
       "[objectives] Error: denied by guardrail (rule pair-boundary, core): not allowed",
       Samagotchi::ToolResponse.interrupted_text("objectives")].each do |text|
        expect(built(chat_model(chat_call("a", { id: "O1", note: "no" })), chat_result("a", "t1", text)).moves).to be_empty
      end
    end

    it "leaves out a call made with no list, which recorded nothing, once a list comes" do
      answer = "[objectives]\n#{Samagotchi::Tools::ObjectivesTool::NONE}"
      conversation = [chat_model(chat_call("a", { id: "O1", note: "before any list" })), chat_result("a", "t1", answer),
                      chat_model(chat_call("b", { id: "O1" })), chat_result("b", "t2", answer), note("n1", list)]

      expect(described_class.build(conversation).moves).to be_empty
    end

    it "takes the running turn's moves over the saved ones" do
      saved = [chat_model(chat_call("a", { id: "O1", note: "saved" })), chat_result("a", "t1"),
               chat_model(chat_call("b", { id: "O2", note: "saved two" })), chat_result("b", "t2", recorded("O2"))]
      running = [chat_model(chat_call("c", { id: "O1", note: "running" })), chat_result("c", "t3")]
      moves = built(*saved, running: running).moves

      expect(moves.transform_values(&:note)).to eq("O1" => "running", "O2" => "saved two")
    end

    it "keeps moves under a pending list, which holds none of its own" do
      newer = list.mark("O1", described_class::DONE)
      built_list = built(chat_model(chat_call("a", { id: "O1", note: "x" })), chat_result("a", "t1"), pending: newer.to_payload)

      expect(built_list.find("O1").status).to eq(described_class::DONE)
      expect(built_list.moves.keys).to eq(["O1"])
    end

    it "keeps a move out of the frame and the payload" do
      built_list = built(chat_model(chat_call("a", { id: "O1", note: "x" })), chat_result("a", "t1"))

      expect(built_list.text).to eq(list.text)
      expect(built_list.to_payload).to eq(list.to_payload)
    end

    it "folds one line of a many-line note" do
      built_list = built(chat_model(chat_call("a", { id: "O1", note: "one\ntwo   three" })), chat_result("a", "t1"))

      expect(built_list.moves.fetch("O1").line).to eq("one two three")
    end
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
