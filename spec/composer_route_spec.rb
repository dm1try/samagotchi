# frozen_string_literal: true

require "json"
require "spec_helper"
require "samagotchi/composer_route"
require "samagotchi/commands/registry"
require "samagotchi/session_commands"

RSpec.describe Samagotchi::ComposerRoute do
  # The shared cases (the web's composer.test.js runs the same file).
  golden = JSON.parse(File.read(File.expand_path("fixtures/composer_routes.json", __dir__)))

  # Every core command with its own matcher (as a worker's session has
  # them), so a new core command or a changed matcher meets every row; a
  # listed name core lacks is a plugin's command, matched by its name.
  def registry_for(names)
    Samagotchi::Commands::Registry.from_listing(names.map { |name| { name: name } },
                                                base: Samagotchi::SessionCommands.builtin_registry)
  end

  # Each core command's bare line, idle and running. A new core command
  # fails "covers every core command" until it is listed here.
  CORE_ROUTES = {
    "!rollback" => %w[command command],
    "/continue" => %w[command command],
    "/models" => %w[command command],
    "/guardrails" => %w[command command],
    "/context" => %w[command command],
    "/model" => %w[command command],
    "/llm-context" => %w[command command],
    "/thinking" => %w[command command],
    "/reasoning-history" => %w[command command],
    "/toolkit" => %w[command command],
    "/parent-answers" => %w[command command],
    "/title" => %w[command command],
    "/working-set" => %w[command command],
    "/help" => %w[command command],
    "/stats" => %w[local local],
    "/recap" => %w[local local],
    "/exit" => %w[local local],
    "/quit" => %w[local local],
    "/archive" => %w[local local],
    "/detach" => %w[local local],
    "/cut" => %w[usage usage],
    "/queue" => %w[usage usage],
    "/unqueue" => %w[local local]
  }.freeze

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

  describe "against every core command" do
    let(:core) { Samagotchi::SessionCommands.builtin_registry }

    it "covers every core command (! is the shell's: a row's !cmd)" do
      expect(CORE_ROUTES.keys).to match_array(core.entries.map(&:name) - ["!"])
    end

    CORE_ROUTES.each do |name, (idle, running)|
      it "routes the bare #{name} as #{idle} idle, #{running} running" do
        registry = registry_for(golden["commands"])
        expect(described_class.call(name, running: false, registry: registry).kind.to_s).to eq(idle)
        expect(described_class.call(name, running: true, registry: registry).kind.to_s).to eq(running)
        # A glued word is no command of it (a ! line is the shell's anyway).
        expect(described_class.call("#{name}x", running: false, registry: registry).kind).to eq(:typo).or eq(:prompt) if name.start_with?("/")
      end
    end

    it "routes a :local line to its entry's id" do
      registry = registry_for(golden["commands"])
      core.entries.select(&:local).reject { |entry| %w[/cut /queue].include?(entry.name) }.each do |entry|
        expect(described_class.call(entry.name, running: false, registry: registry).local).to eq(entry.id), entry.name
      end
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

  it "uses a listed core command's builtin matcher, but matches plugin commands by name" do
    expect(registry_for(["/context"]).lookup("/CONTEXT").id).to eq(:context)
    expect(registry_for(["/plugin"]).lookup("/plugin argument").name).to eq("/plugin")
  end

  it "reads /cut and /queue as the registry's entries match them (any space after the word)" do
    expect(described_class.steer_choice("/cut\tdrop it")).to eq([:cut, "drop it"])
    expect(described_class.steer_choice("/queue\nthen this")).to eq([:queue, "then this"])
    expect(described_class.steer_choice("  /cut   ")).to eq([:cut, ""])
    expect(described_class.steer_choice("/cutter x")).to be_nil
    expect(described_class.steer_choice("/queued")).to be_nil
  end
end
