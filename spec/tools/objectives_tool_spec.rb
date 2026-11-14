# frozen_string_literal: true

require "spec_helper"
require "samagotchi/tools/builtins"
require "samagotchi/tools/builtin_calls"
require "samagotchi/toolkit"
require "samagotchi/tool_activity"

RSpec.describe Samagotchi::Tools::ObjectivesTool do
  let(:list) do
    Samagotchi::Objectives::List.new.set([{ text: "Two coffees" }, { text: "Stops before checkout" }])
  end
  let(:peers) { Struct.new(:objectives).new(list) }

  def move(**args) = described_class.call(args, peers: peers)

  describe "propose" do
    let(:peers) do
      Struct.new(:objectives, :proposed) do
        def propose_objective(proposal) = (self.proposed = proposal)
      end.new(list)
    end

    def propose(**args) = described_class.call({ action: "propose", note: "why", **args }, peers: peers)

    it "queues a proposal and says the list is unchanged until the user applies it" do
      answer = propose(change: "done", id: "o2")
      expect(answer).to include("Proposed", "unchanged", "the user")
      expect(peers.proposed.line).to eq("/objectives done O2")
      expect(peers.proposed.note).to eq("why")
    end

    it "builds each change's own line, its text one line, a | not splitting an add" do
      propose(change: "add", text: "Do\nA | B")
      expect(peers.proposed.line).to eq("/objectives add Do A / B")
      propose(change: "reword", id: "O1", text: "One | two")
      expect(peers.proposed.line).to eq("/objectives edit O1 One | two")
      propose(change: "drop", id: "O1")
      expect(peers.proposed.line).to eq("/objectives drop O1")
    end

    it "keeps no pipe that would split an add, side by side ones too" do
      propose(change: "add", text: "alpha | | beta | gamma")
      expect(peers.proposed.line).to eq("/objectives add alpha / / beta / gamma")
    end

    it "keeps a reworded item's done-when, on the card and in the apply, unless the text brings its own" do
      peers.objectives = list.reword("O2", "Stops", done_when: "no order")
      propose(change: "reword", id: "O2", text: "Halts")
      expect(peers.proposed.line).to eq("/objectives edit O2 Halts (done when: no order)")
      expect(peers.proposed.body).to include("Halts (done when: no order)")
      propose(change: "reword", id: "O2", text: "Halts (done when: at the cart)")
      expect(peers.proposed.line).to eq("/objectives edit O2 Halts (done when: at the cart)")
    end

    it "carries what a reword was proposed against in its card's action" do
      propose(change: "reword", id: "O1", text: "New")
      stamp = Samagotchi::Objectives.fingerprint(list.find("O1"))
      expect(peers.proposed.action_line("c1")).to eq("/objectives --card c1 --was #{stamp} edit O1 New")
      propose(change: "done", id: "O1")
      expect(peers.proposed.action_line("c1")).to eq("/objectives --card c1 done O1")
    end

    it "says so when the turn has proposed enough" do
      refusing = Struct.new(:objectives) { def propose_objective(_) = false }.new(list)
      answer = described_class.call({ action: "propose", change: "done", id: "O1", note: "n" }, peers: refusing)
      expect(answer).to start_with("Error:")
      expect(answer).to include("at most 3")
    end

    it "refuses what can't apply, and proposes nothing" do
      expect(propose(change: "explode", id: "O1")).to start_with("Error:")
      expect(propose(change: "done", id: "O9")).to start_with("Error: no objective O9")
      expect(propose(change: "add")).to start_with("Error:")
      expect(propose(change: "reword", id: "O1", text: " ")).to start_with("Error:")
      expect(peers.proposed).to be_nil
    end

    # The card's Apply runs the proposal's line through /objectives: what it
    # would refuse, the tool refuses, so no card is left that can't apply.
    describe "what the card's Apply would refuse" do
      def applied(line)
        verb, rest = line.delete_prefix("/objectives ").split(/\s+/, 2)
        Samagotchi::Objectives::Edit.apply(peers.objectives, verb, rest.to_s)
      end

      ["(done when: tests pass)", "[done]", "[active] [done]", "[done] (done when: x)"].each do |text|
        it "refuses an add whose text is only #{text}, which Apply refuses too" do
          answer = propose(change: "add", text: text)
          expect(answer).to eq("Error: add needs a text of its own, not only a status or a done-when. Nothing was proposed.")
          expect(peers.proposed).to be_nil
          expect(applied("/objectives add #{text}")).to be_nil
        end

        it "refuses a reword whose text is only #{text}" do
          expect(propose(change: "reword", id: "O1", text: text)).to start_with("Error: reword needs a text of its own")
          expect(peers.proposed).to be_nil
          expect(applied("/objectives edit O1 #{text}")).to be_nil
        end
      end

      it "refuses a status-only reword of an item that keeps a done-when" do
        peers.objectives = list.reword("O2", "Stops", done_when: "no order")
        expect(propose(change: "reword", id: "O2", text: "[done]")).to start_with("Error: reword needs a text of its own")
        expect(peers.proposed).to be_nil
      end

      it "refuses done for a dropped item, as Apply does, with the way back" do
        peers.objectives = list.mark("O1", Samagotchi::Objectives::DROPPED)
        answer = propose(change: "done", id: "O1")
        expect(answer).to start_with("Error: O1 is dropped").and include("/objectives undo O1")
        expect(peers.proposed).to be_nil
        expect(applied("/objectives done O1")).to be_a(String)
      end

      it "still proposes what Apply takes: a drop of a dropped item, a status-led text with words of its own" do
        peers.objectives = list.mark("O1", Samagotchi::Objectives::DROPPED)
        expect(propose(change: "drop", id: "O1")).to start_with("Proposed")
        expect(propose(change: "add", text: "[done] Ship it")).to start_with("Proposed")
        expect(applied(peers.proposed.line)).to be_a(Samagotchi::Objectives::List)
      end
    end

    it "answers plainly with no list, and is never a move" do
      empty = Struct.new(:objectives).new(Samagotchi::Objectives::List.new)
      expect(described_class.call({ action: "propose", change: "done", id: "O1", note: "n" }, peers: empty)).to eq(described_class::NONE)
      expect(described_class.recorded?(propose(change: "done", id: "O1"), "O1")).to be(false)
    end
  end

  it "records a move and says that it doesn't edit the list, and who does" do
    answer = move(action: "move", id: "O2", note: "Checkout stays closed", evidence: "spec green")

    expect(answer).to start_with("Recorded a move on O2.")
    expect(answer).to include("The list is unchanged", "/objectives")
  end

  it "takes a call with no action as a move, and an id in any case" do
    expect(move(id: " o1 ", note: "x")).to start_with("Recorded a move on O1.")
  end

  it "answers plainly when the session has no list" do
    empty = Struct.new(:objectives).new(Samagotchi::Objectives::List.new)

    expect(described_class.call({ id: "O1", note: "x" }, peers: empty)).to eq(described_class::NONE)
    expect(described_class.call({ id: "O1", note: "x" }, peers: nil)).to eq(described_class::NONE)
    expect(described_class::NONE).to include("no objectives here")
    expect(described_class::NONE).not_to start_with("Error")
  end

  it "refuses an unknown id, and names the ones there are" do
    expect(move(id: "O9", note: "x")).to eq("Error: no objective O9 (this session's: O1, O2). Nothing was recorded.")
  end

  it "refuses a dropped objective: it is off the list the model is shown" do
    peers.objectives = list.mark("O1", Samagotchi::Objectives::DROPPED)

    expect(move(id: "O1", note: "x")).to eq("Error: #{Samagotchi::Objectives.dropped("O1")}. Nothing was recorded.")
  end

  it "takes a move on a done objective: work can still touch it" do
    peers.objectives = list.mark("O1", Samagotchi::Objectives::DONE)

    expect(move(id: "O1", note: "x")).to start_with("Recorded a move on O1.")
  end

  it "needs a note" do
    expect(move(id: "O1", note: "  ")).to start_with("Error: a move needs a note")
  end

  describe "a move's state" do
    it "takes progress, blocked or done in any case, and records it as a move" do
      ["progress", " Blocked ", "DONE", nil, ""].each do |state|
        expect(move(id: "O1", note: "x", state: state)).to start_with("Recorded a move on O1.")
      end
    end

    it "reads a missing one as progress, an unknown one as none" do
      expect(described_class.state_of({})).to eq("progress")
      expect(described_class.state_of({ state: " Done " })).to eq("done")
      expect(described_class.state_of({ state: "finished" })).to be_nil
    end

    it "refuses an unknown one, naming the three, and records nothing" do
      answer = move(id: "O1", note: "x", state: "finished")

      expect(answer).to eq("Error: a move's state must be progress, blocked or done. Nothing was recorded.")
      expect(described_class.recorded?("[objectives]\n#{answer}", "O1")).to be(false)
    end

    it "maps through BuiltinCalls" do
      call = Samagotchi::Tools::BuiltinCalls.build("objectives", { "id" => "O1", "note" => "n", "state" => "done" })

      expect(call).to include(state: "done")
    end
  end

  it "refuses any other action and says the user edits the list" do
    answer = move(action: "done", id: "O1", note: "x")

    expect(answer).to start_with("Error: this tool records a move")
    expect(answer).to include("/objectives")
    expect(answer).not_to include("done")
  end

  describe "its declaration" do
    let(:schema) { Samagotchi::ToolDeclarations::TOOL_SCHEMAS.find { |s| s[:name] == "objectives" } }

    it "is one of the turn's tools" do
      expect(schema).not_to be_nil
    end

    it "says it records and doesn't edit, and that the user edits with /objectives" do
      expect(schema[:description]).to include("doesn't edit the list", "/objectives")
    end

    it "maps through BuiltinCalls" do
      call = Samagotchi::Tools::BuiltinCalls.build("objectives",
                                                   { "action" => "move", "id" => "O1", "note" => " n ", "evidence" => "e" })

      expect(call).to include(name: "objectives", content: "n", action: "move", id: "O1", note: "n", evidence: "e")
    end

    it "is declared on full and left out of lean, reachable by call_tool" do
      registry = Samagotchi::Tools::Builtins.registry
      entry = registry["objectives"]
      kits = Samagotchi::Toolkit::BUILTIN_KITS

      expect(Samagotchi::Toolkit.new(name: "full").resolve(kits).declares?(entry)).to be(true)
      %w[lean child].each do |kit|
        expect(Samagotchi::Toolkit.new(name: kit).resolve(kits).declares?(entry)).to be(false)
      end
      expect(Samagotchi::Toolkit.new(name: "lean", add: ["objectives"]).resolve(kits).declares?(entry)).to be(true)
    end

    it "runs through the built-in handler with the kernel's peers" do
      kctx = Struct.new(:peers).new(peers)
      answer = Samagotchi::Tools::Builtins.registry["objectives"].handler.call({ action: "move", id: "O1", note: "n" }, kctx)

      expect(answer).to start_with("Recorded a move on O1.")
    end
  end

  describe ".recorded?" do
    it "holds only for the answer that recorded this id" do
      answer = "[objectives]\n#{move(id: "O1", note: "n")}"

      expect(described_class.recorded?(answer, "O1")).to be(true)
      expect(described_class.recorded?(answer, "O2")).to be(false)
      expect(described_class.recorded?("[objectives]\n#{described_class::NONE}", "O1")).to be(false)
      expect(described_class.recorded?("[objectives] Error: denied", "O1")).to be(false)
    end
  end

  describe "its row" do
    it "reads as the move" do
      call = { name: "objectives", id: "O2", note: "Checkout stays closed", evidence: "spec green" }

      expect(Samagotchi::ToolActivity.tool_activity_event("objectives", call, "Recorded"))
        .to eq(action: "recording a move", tool: "objectives", status: "ok", title: "O2 Checkout stays closed · spec green",
               params: 'id="O2" note="Checkout stays closed" evidence="spec green"')
    end

    it "carries a blocked or done state in its params, before the note, and keeps the title" do
      call = { name: "objectives", id: "O2", note: "Checkout stays closed", state: " Done " }
      event = Samagotchi::ToolActivity.tool_activity_event("objectives", call, "Recorded")

      expect(event[:params]).to eq('id="O2" state="done" note="Checkout stays closed"')
      expect(event[:title]).to eq("O2 Checkout stays closed")
    end

    it "says nothing of progress, an unknown state or a proposal's" do
      [{ state: "progress" }, { state: "finished" }, { action: "propose", change: "done", state: "done" }].each do |extra|
        params = Samagotchi::ToolActivity.tool_activity_params("objectives", { id: "O2", note: "n", **extra })
        expect(params).not_to include("state=")
      end
    end
  end
end
