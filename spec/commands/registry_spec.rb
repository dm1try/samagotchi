# frozen_string_literal: true

require "json"
require "samagotchi/commands/registry"
require "samagotchi/session_commands"

RSpec.describe Samagotchi::Commands::Registry do
  subject(:registry) { described_class.new }

  it "looks a line up by its name, alone or with arguments" do
    entry = registry.register("/hello", "say hello")
    expect(registry.lookup("/hello")).to be(entry)
    expect(registry.lookup("  /hello world ")).to be(entry)
    expect(registry.lookup("/hellox")).to be_nil
    expect(entry.id).to eq(:hello)
    expect(entry.source).to eq("core")
  end

  it "takes a custom match, first registered wins" do
    first = registry.register("!rollback", "roll back", id: :rollback)
    registry.register("!", "shell", id: :shell, match: ->(text) { text.start_with?("!") })
    expect(registry.lookup("!rollback")).to be(first)
    expect(registry.lookup("!ls").id).to eq(:shell)
  end

  it "never looks up a local entry, but offers it for completion in its UIs" do
    registry.register("/model", "model")
    registry.register("/stats", "stats", local: true)
    registry.register("/detach", "detach", local: true, uis: [:attached])
    registry.register("!", "shell", match: ->(text) { text.start_with?("!") })
    expect(registry.command?("/stats")).to be(false)
    expect(registry.completions(:repl)).to eq(%w[/model /stats])
    expect(registry.completions(:attached)).to eq(%w[/detach /model /stats])
  end

  it "refuses a second entry with the same name, and a frozen registry refuses any" do
    registry.register("/a", "a")
    expect { registry.register("/a", "again") }.to raise_error(ArgumentError, /already registered/)
    registry.freeze
    expect { registry.register("/b", "b") }.to raise_error(FrozenError)
  end

  describe "#listing and .from_listing (a snapshot's commands)" do
    it "lists each entry for a UI without an Engine" do
      registry.register("/hello", "greet", anytime: true, source: "sample-plugin")
      registry.register("/detach", "detach", local: true, uis: [:attached])
      expect(registry.listing).to eq([
        { name: "/hello", description: "greet", anytime: true, local: false, uis: nil, source: "sample-plugin" },
        { name: "/detach", description: "detach", local: true, anytime: false, uis: ["attached"], source: "core" }
      ])
    end

    it "keeps the base's entries (their match) and adds the listed ones it lacks, JSON keys too" do
      base = Samagotchi::SessionCommands.builtin_registry
      listing = JSON.parse(JSON.generate(base.listing + [{ name: "/hello", description: "greet", anytime: true,
                                                           local: false, uis: nil, source: "sample-plugin" }]))
      rebuilt = described_class.from_listing(listing, base: base)

      expect(rebuilt.lookup("!ls").id).to eq(:shell)
      expect(rebuilt.lookup("/model x").id).to eq(:model)
      hello = rebuilt.lookup("/hello again")
      expect([hello.name, hello.anytime, hello.source]).to eq(["/hello", true, "sample-plugin"])
      expect(rebuilt.lookup("/foo")).to be_nil
      expect(rebuilt.completions(:attached)).to include("/hello", "/detach")
      expect(base.lookup("/hello")).to be_nil
    end
  end

  describe "the built-ins (SessionCommands.builtin_registry)" do
    let(:builtins) { Samagotchi::SessionCommands.builtin_registry }

    it "offers the same Tab lists the REPL and the attached TUI had" do
      expect(builtins.completions(:repl)).to eq(%w[/continue /exit /guardrails /model /models /recap /stats])
      expect(builtins.completions(:attached))
        .to eq(%w[/continue /detach /exit /guardrails /model /models /quit /recap /stats])
    end

    it "is frozen, and each command #run runs has a handler" do
      expect(builtins).to be_frozen
      runnable = builtins.entries.reject(&:local)
      expect(runnable.map(&:id)).to eq(%i[rollback shell continue models guardrails model])
      expect(runnable.map(&:handler)).to all(be_a(Proc))
    end
  end
end
