# frozen_string_literal: true

require "json"
require "spec_helper"
require "samagotchi/composer_route"
require "samagotchi/commands/registry"
require "samagotchi/session_commands"

RSpec.describe Samagotchi::ComposerRoute do
  # The shared cases (the web's composer.test.js runs the same file).
  golden = JSON.parse(File.read(File.expand_path("fixtures/composer_routes.json", __dir__)))

  # The terminals' own words and !cmd (every session has them), then the
  # row's session commands by name, as an attached TUI's registry is built
  # from a snapshot's listing.
  def registry_for(names)
    base = Samagotchi::SessionCommands.builtin_registry.entries.select { |entry| entry.local || entry.id == :shell }
    Samagotchi::Commands::Registry.from_listing(names.map { |name| { name: name } },
                                                base: Samagotchi::Commands::Registry.new(entries: base))
  end

  def expect_route(route, expected, row)
    label = "#{row["text"].inspect} running: #{row["running"]}"
    expect(route.kind.to_s).to eq(expected["kind"]), label
    expect(route.text).to eq(expected["text"]), label if expected.key?("text")
    expect(route.delivery).to eq(expected["delivery"]), label
    expect(route.local.to_s).to eq(expected["local"]), label if expected.key?("local")
  end

  golden["rows"].each do |row|
    it "routes #{row["text"].inspect}#{" (running)" if row["running"]}#{" with #{row["images"]} images" if row["images"]}" do
      registry = registry_for(row["commands"] || golden["commands"])
      route = described_class.call(row["text"], running: row["running"], registry: registry, images: row["images"] || 0)

      expect_route(route, row["expect"], row)
    end
  end

  it "keeps the word a line was typed with, an idle one's routed text too" do
    registry = registry_for(golden["commands"])

    expect(described_class.call("/cut /model y", running: false, registry: registry).choice).to eq(:cut)
    expect(described_class.call("/queue x", running: true, registry: registry).choice).to eq(:queue)
    expect(described_class.call("hello", running: true, registry: registry).choice).to be_nil
  end

  it "gives a typo the registry's hint" do
    route = described_class.call("/modle", running: false, registry: registry_for(["/model"]))

    expect(route.reply).to eq("Unknown command /modle. Did you mean /model? /help lists the commands.")
  end

  it "reads /cut and /queue as the registry's entries match them (any space after the word)" do
    expect(described_class.steer_choice("/cut\tdrop it")).to eq([:cut, "drop it"])
    expect(described_class.steer_choice("/queue\nthen this")).to eq([:queue, "then this"])
    expect(described_class.steer_choice("  /cut   ")).to eq([:cut, ""])
    expect(described_class.steer_choice("/cutter x")).to be_nil
    expect(described_class.steer_choice("/queued")).to be_nil
  end
end
