# frozen_string_literal: true

require "spec_helper"
require "samagotchi/toolkit"
require "samagotchi/tools/builtins"

RSpec.describe Samagotchi::Toolkit do
  let(:kits) { described_class.kits }
  let(:builtins) { Samagotchi::Tools::Builtins.default.names }

  # The built-ins +toolkit+ declares, in registry order.
  def declared(resolved)
    Samagotchi::Tools::Builtins.default.entries.select { |entry| resolved.declares?(entry) }.map(&:name)
  end

  describe "the built-in kits" do
    it "full declares every built-in" do
      expect(declared(described_class.new(name: "full").resolve(kits))).to eq(builtins)
    end

    it "lean leaves out the delegate, session and reminder tools" do
      resolved = described_class.new(name: "lean").resolve(kits)
      expect(builtins - declared(resolved)).to eq(%w[register_reminder cancel_reminder list_reminders list_sessions
                                                     send_note delegate delegate_result])
      expect(resolved.fallback).to be_nil
    end

    it "child is lean with send_note, and removes memory_write and the delegate tools (unreachable)" do
      lean = declared(described_class.new(name: "lean").resolve(kits))
      resolved = described_class.new(name: "child").resolve(kits)
      child = declared(resolved)
      expect(child - lean).to eq(%w[send_note])
      expect(lean - child).to eq(%w[memory_write])
      expect(resolved.removed).to eq(%w[memory_write delegate delegate_result])
    end
  end

  it "keeps a layer's tool (forget_outputs) and every plugin tool, unless removed" do
    registry = Samagotchi::Tools::Builtins.registry
    registry.register("mcp_x", schema: { name: "mcp_x" }, handler: ->(*) {}, source: "mcp")
    lean = described_class.new(name: "lean").resolve(kits)
    expect(lean.declares?(registry["forget_outputs"])).to be(true)
    expect(lean.declares?(registry["mcp_x"])).to be(true)
    expect(described_class.new(name: "lean", remove: ["mcp_x"]).resolve(kits).declares?(registry["mcp_x"])).to be(false)
  end

  it "puts the session's own add and remove on top of its kit" do
    resolved = described_class.new(name: "lean", add: ["delegate"], remove: ["web_fetch"]).resolve(kits)
    expect(declared(resolved)).to include("delegate")
    expect(declared(resolved)).not_to include("web_fetch")
  end

  it "resolves a config kit through its base chain" do
    config = { "review" => { "base" => "child", "add" => %w[web_fetch delegate] },
               "deep" => { "base" => "review", "remove" => ["delegate"] } }
    deep = declared(described_class.new(name: "deep").resolve(described_class.kits(config: config)))
    expect(deep).to eq(declared(described_class.new(name: "child").resolve(kits)))
  end

  it "falls back to full for an unknown name or a cycle, and keeps its own name" do
    toolkit = described_class.new(name: "nope")
    resolved = toolkit.resolve(kits)
    expect(declared(resolved)).to eq(builtins)
    expect(resolved.fallback).to eq("no toolkit named nope")
    expect(toolkit.name).to eq("nope")

    looped = described_class.kits(config: { "a" => { "base" => "b" }, "b" => { "base" => "a" } })
    expect(described_class.new(name: "a").resolve(looped).fallback).to include("cycle (a → b → a)")
  end

  it "puts a config kit without a base (or base: ~) on full" do
    kits = described_class.kits(config: { "a" => { "base" => nil, "remove" => ["delegate"] }, "b" => { "add" => [] } })
    expect(declared(described_class.new(name: "a").resolve(kits))).to eq(builtins - ["delegate"])
    expect(declared(described_class.new(name: "b").resolve(kits))).to eq(builtins)
  end

  it "refuses a config kit with a built-in's name or a bad shape" do
    errors = []
    kits = described_class.kits(config: { "lean" => { "base" => "full" }, "odd" => "lean" }, errors: errors)
    expect(kits["lean"].source).to eq("core")
    expect(kits).not_to have_key("odd")
    expect(errors).to eq(["toolkit.kits.lean: lean is a built-in toolkit", "toolkit.kits.odd: expected {base:, add:, remove:, prompt:}"])
  end

  it "loads a config kit with an unknown key and warns about the key (a typo, not a broken kit)" do
    errors = []
    kits = described_class.kits(config: { "review" => { "base" => "lean", "tools" => ["read"], remvoe: ["x"] } },
                                errors: errors)
    expect(kits["review"].base).to eq("lean")
    expect(errors).to eq(["toolkit.kits.review: unknown key tools (a kit takes base:, add:, remove:, prompt:)",
                          "toolkit.kits.review: unknown key remvoe (a kit takes base:, add:, remove:, prompt:)"])
  end

  it "doesn't let a plugin kit replace one already known" do
    plugin = described_class::Kit.new(name: "lean", tools: :all, source: "mine")
    expect(described_class.kits(plugins: [plugin])["lean"].source).to eq("core")
  end

  it "reads and writes the session file's form; nil and garbage read as none" do
    toolkit = described_class.new(name: "lean", add: ["delegate"], remove: [])
    expect(described_class.from_file(toolkit.to_file)).to eq(toolkit)
    expect(described_class.from_file(nil)).to be_nil
    expect(described_class.from_file({ "add" => [] })).to be_nil
    expect(described_class.from_file("child")).to eq(described_class.new(name: "child"))
    expect(described_class.of(nil)).to be_full
  end

  it "adds and removes a tool, always recorded: a remove after an add is hard, an add after a remove declares (D12)" do
    toolkit = described_class.new(name: "lean").adding("delegate").removing("web_fetch")
    expect(toolkit.label).to eq("lean +delegate -web_fetch")
    expect(toolkit.removing("delegate").adding("web_fetch")).to eq(described_class.new(name: "lean", add: ["web_fetch"],
                                                                                       remove: ["delegate"]))
    resolved = described_class.new(name: "lean").adding("delegate").removing("delegate").resolve(kits)
    expect(resolved.removed).to eq(["delegate"])
    resolved = described_class.new(name: "lean").removing("delegate").adding("delegate").resolve(kits)
    expect(resolved.added).to eq(["delegate"])
    expect(resolved.removed).to eq([])
  end

  it "costs a full prompt re-read when the declared names change" do
    expect(described_class.cache_cost(%w[a b], %w[a b])).to be_nil
    expect(described_class.cache_cost(%w[a b], %w[a])).to eq(:full)
  end

  describe "a kit's prompt text" do
    let(:config) do
      { "terse" => { "base" => "lean", "prompt" => "  - Be concise\n- Show paths  \n" },
        "review" => { "base" => "terse", "add" => ["web_fetch"] },
        "plain" => { "base" => "terse", "prompt" => "" },
        "loud" => { "prompt" => "Say more." } }
    end
    let(:kits) { described_class.kits(config: config) }

    def resolved(name, **changes) = described_class.new(name: name, **changes).resolve(kits)

    it "resolves stripped, is inherited through a base, and \"\" clears it" do
      expect(resolved("terse").prompt).to eq("- Be concise\n- Show paths")
      expect(resolved("review").prompt).to eq("- Be concise\n- Show paths")
      expect(resolved("plain").prompt).to be_nil
      expect(resolved("lean").prompt).to be_nil
      expect(resolved("nope").prompt).to be_nil
    end

    it "is kept by the session's own add and remove" do
      expect(resolved("terse", add: ["delegate"], remove: ["web_fetch"]).prompt).to eq("- Be concise\n- Show paths")
    end

    it "keeps a kit on full's tools from reading as full (everything?), and it declares every built-in" do
      loud = resolved("loud")
      expect(loud.everything?).to be(false)
      expect(loud.prompt).to eq("Say more.")
      expect(declared(loud)).to eq(builtins)
      expect(resolved("full").everything?).to be(true)
    end

    it "loads a config kit without a prompt that isn't text or is too long, with a line saying why" do
      errors = []
      kits = described_class.kits(config: { "a" => { "base" => "lean", "prompt" => ["x"] },
                                            "b" => { "base" => "lean", "prompt" => "x" * 2001 },
                                            "c" => { "base" => "lean", "prompt" => "x" * 2000 } }, errors: errors)
      expect(kits["a"].prompt).to be_nil
      expect(kits["b"].prompt).to be_nil
      expect(kits["c"].prompt.length).to eq(2000)
      expect(errors).to eq(["toolkit.kits.a: prompt must be text; the kit loads without it",
                            "toolkit.kits.b: prompt is over 2000 characters; the kit loads without it"])
    end

    describe "Explained" do
      def explained(name)
        Samagotchi::Toolkit::Explained.new(toolkit: Samagotchi::Toolkit.new(name: name), resolved: resolved(name),
                                           declared: [], left_out: [], pending: false)
      end

      it "has a prompt key that differs when only the text differs" do
        expect(explained("terse").prompt_key).not_to eq(explained("lean").prompt_key)
        expect(explained("terse").prompt_key).to eq(explained("review").prompt_key)
      end

      it "puts the text in the UIs' summary only when the kit has one" do
        expect(explained("terse").summary).to include(name: "terse", prompt: "- Be concise\n- Show paths")
        expect(explained("lean").summary).not_to have_key(:prompt)
        expect(explained("full").summary).to be_nil
      end
    end
  end

  it "builds a new session's toolkit from the flags, on config's default without --toolkit" do
    expect(described_class.from_flags).to be_nil
    expect(described_class.from_flags(name: "lean", add: ["delegate,send_note"], remove: ["send_note"]))
      .to eq(described_class.new(name: "lean", add: ["delegate"], remove: ["send_note"]))
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("toolkit.default").and_return("child")
    expect(described_class.from_flags(add: ["delegate"])).to eq(described_class.new(name: "child", add: ["delegate"]))
  end
end
