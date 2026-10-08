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

  describe "#unknown_command_word? and #unknown_command_hint" do
    let(:builtins) { Samagotchi::SessionCommands.builtin_registry }

    it "hints a close name for a typo of a command" do
      expect(builtins.unknown_command_word?("/modle")).to be(true)
      expect(builtins.unknown_command_hint("/modle")).to eq("Unknown command /modle. Did you mean /model? /help lists the commands.")
    end

    it "hints without a name when nothing is close" do
      expect(builtins.unknown_command_hint("/xyz")).to eq("Unknown command /xyz. /help lists the commands.")
    end

    it "is nil for a command, a command with arguments, and anything that is a prompt" do
      expect(builtins.unknown_command_hint("/model")).to be_nil
      expect(builtins.unknown_command_hint("/model x")).to be_nil
      expect(builtins.unknown_command_hint("/foo bar")).to be_nil
      expect(builtins.unknown_command_hint("/usr/bin/env")).to be_nil
      expect(builtins.unknown_command_hint("!ls")).to be_nil
      expect(builtins.unknown_command_hint("hello")).to be_nil
      expect(builtins.unknown_command_hint("")).to be_nil
    end

    it "is nil for a local command (the UI runs it) and for a bundle's command" do
      registry.register("/hello", "greet", source: "sample-plugin")
      registry.register("/stats", "stats", local: true)
      expect(registry.unknown_command_hint("/hello")).to be_nil
      expect(registry.unknown_command_hint("/stats")).to be_nil
      expect(registry.unknown_command_hint("/helo")).to eq("Unknown command /helo. Did you mean /hello? /help lists the commands.")
    end
  end

  describe "#listing and .from_listing (a snapshot's commands)" do
    it "lists each entry for a UI without an Engine" do
      registry.register("/hello", "greet", anytime: true, source: "sample-plugin")
      registry.register("/detach", "detach", local: true, uis: [:attached])
      expect(registry.listing).to eq([
        { name: "/hello", description: "greet", anytime: true, mid_turn: "anytime", local: false, uis: nil, source: "sample-plugin" },
        { name: "/detach", description: "detach", local: true, anytime: false, mid_turn: "refuse", uis: ["attached"], source: "core" }
      ])
    end

    it "lists a line's own mid-turn policy as depends, not anytime" do
      registry.register("/show", "show or set", mid_turn: ->(text) { text == "/show" ? :anytime : :refuse })
      expect(registry.listing.first).to include(anytime: false, mid_turn: "depends")
    end

    it "takes a listed mid_turn, an older worker's anytime alone, and refuses depends or an unknown one" do
      base = described_class.new
      listing = [{ name: "/a", mid_turn: "anytime" }, { name: "/b", anytime: true }, { name: "/c", mid_turn: "depends" },
                 { name: "/d", mid_turn: "later" }, { name: "/e" }]
      rebuilt = described_class.from_listing(JSON.parse(JSON.generate(listing)), base: base)
      expect(%w[/a /b /c /d /e].map { |line| rebuilt.mid_turn(line) }).to eq(%i[anytime anytime refuse refuse refuse])
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

  describe "#mid_turn (what a line does while a turn runs)" do
    it "is the entry's, :refuse by default and for a line no command answers" do
      registry.register("/side", "side", anytime: true)
      registry.register("/set", "set")
      registry.register("/stats", "stats", local: true)
      expect(registry.mid_turn(" /side q ")).to eq(:anytime)
      expect(registry.mid_turn("/set x")).to eq(:refuse)
      expect(registry.mid_turn("/stats")).to eq(:refuse)
      expect(registry.mid_turn("hello")).to eq(:refuse)
      expect(registry.lookup("/side").anytime).to be(true)
      expect(registry.lookup("/set").anytime).to be(false)
    end

    it "asks the entry's lambda with the stripped line" do
      seen = []
      registry.register("/show", "show or set", mid_turn: lambda { |text|
        seen << text
        text == "/show" ? :anytime : :refuse
      })
      expect([registry.mid_turn(" /show "), registry.mid_turn("/show x")]).to eq(%i[anytime refuse])
      expect(seen).to eq(["/show", "/show x"])
      expect(registry.lookup("/show").anytime).to be(false)
    end
  end

  describe "the built-ins (SessionCommands.builtin_registry)" do
    let(:builtins) { Samagotchi::SessionCommands.builtin_registry }

    it "offers the same Tab lists in the REPL and the attached TUI, but /detach (the REPL owns its session)" do
      expect(builtins.completions(:repl)).to eq(%w[/archive /context /continue /exit /guardrails /help /llm-context /model /models /quit /recap /stats])
      expect(builtins.completions(:attached))
        .to eq(%w[/archive /context /continue /detach /exit /guardrails /help /llm-context /model /models /quit /recap /stats])
    end

    # Both terminal UIs dispatch their own commands on these ids.
    it "names the terminal's own commands by id, whatever the case, with --delete after an exit word" do
      ids = ["exit", "/exit", "/EXIT --DELETE", "/quit", "/quit --delete", "/archive", "/ARCHIVE", "/detach", "/Detach",
             "/stats", "/stats now", "/recap"].map { |line| builtins.lookup_local(line)&.id }
      expect(ids).to eq(%i[exit exit exit exit exit archive archive detach detach stats stats recap])
      expect(["quit", "exit now", "/exit --force", "/archive now", "/model", "no exit"].map { |line| builtins.lookup_local(line) })
        .to all(be_nil)
      expect(builtins.lookup("/exit")).to be_nil
      expect(["/exit --delete", "EXIT --DELETE", "/quit --delete"].map { |l| Samagotchi::SessionCommands.delete_on_exit?(l) }).to all(be(true))
      expect(Samagotchi::SessionCommands.delete_on_exit?("/exit")).to be(false)
    end

    it "is frozen, and each command #run runs has a handler" do
      expect(builtins).to be_frozen
      runnable = builtins.entries.reject(&:local)
      expect(runnable.map(&:id)).to eq(%i[rollback shell continue models guardrails context model llm_context help])
      expect(runnable.map(&:handler)).to all(be_a(Proc))
    end
  end
end
