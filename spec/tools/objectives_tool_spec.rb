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

    expect(move(id: "O1", note: "x")).to start_with("Error: O1 was dropped")
  end

  it "takes a move on a done objective: work can still touch it" do
    peers.objectives = list.mark("O1", Samagotchi::Objectives::DONE)

    expect(move(id: "O1", note: "x")).to start_with("Recorded a move on O1.")
  end

  it "needs a note" do
    expect(move(id: "O1", note: "  ")).to start_with("Error: a move needs a note")
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
      %w[lean child review].each do |kit|
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
  end
end
