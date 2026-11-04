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

    expect(answer).to start_with("Error: this tool only records a move")
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
