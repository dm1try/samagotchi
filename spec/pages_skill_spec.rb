# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "samagotchi/bundle_manifest"
require "samagotchi/pages"
require "samagotchi/pages/builder"
require "samagotchi/pages/runner"
require "samagotchi/page_command"

# The system bundle's pages skill (lib/samagotchi/bundles/system/skill_pages.md)
# against the code it teaches: its worked example runs through the builder,
# every command and call it names exists, and every limit it states is the
# constant's. The skill can't drift from Pages without one of these failing.
RSpec.describe "The pages skill" do
  DIR = File.expand_path("../lib/samagotchi/bundles/system", __dir__)
  EXAMPLE = /^```ruby\n(.*?)^```$/m

  let(:text) { File.read(File.join(DIR, "skill_pages.md")) }
  let(:example) { text.scan(EXAMPLE).map(&:first) }

  # The sessions `chi sessions list --scope=all --format json` gives the
  # example in place of the real command.
  let(:sessions) do
    [{ "id" => "a", "project" => "/p/alpha", "updated_at" => "2026-11-22T10:00:00.000+01:00" },
     { "id" => "b", "project" => "/p/beta", "updated_at" => "2026-11-22T09:00:00.000+01:00" },
     { "id" => "c", "project" => "/p/alpha", "updated_at" => "2026-11-20T09:00:00.000+01:00" }]
  end

  # The example loaded as the runner loads a script (Kernel#load with the
  # Collector's DSL as its wrap), Open3.capture2 standing in for the command.
  def run_example(code, success: true)
    status = instance_double(Process::Status, success?: success, exitstatus: success ? 0 : 1)
    allow(Open3).to receive(:capture2).with("chi", "sessions", "list", "--scope=all", "--format", "json")
                                      .and_return([JSON.generate(sessions), status])
    collector = Samagotchi::Pages::Runner::Collector.new
    Dir.mktmpdir("pages-skill") do |dir|
      path = File.join(dir, "example.rb")
      File.write(path, code)
      load(path, collector.dsl)
    end
    collector.builder.data
  end

  it "starts as a skill does and has its index line in the manifest, under 200 characters" do
    expect(text).to start_with("# Skill: pages\n")
    description = Samagotchi::BundleManifest.read(dir: DIR).file_descriptions["skill_pages.md"]
    expect(description).to include("chi page run", "#/p/NAME")
    expect(description.length).to be < 200
  end

  it "has exactly one ruby example, and it builds through the page DSL the blocks the text says" do
    expect(example.size).to eq(1)
    data = run_example(example.first)
    expect(data["title"]).to eq("Sessions per day")
    expect(data["blocks"].map { |block| block["type"] }).to eq(%w[text table])
    expect(data["blocks"][0]["text"]).to eq("3 sessions on 2 days.")
    table = data["blocks"][1]
    expect(table["columns"].map { |c| c["key"] }).to eq(%w[day sessions projects])
    expect(table["columns"].find { |c| c["key"] == "sessions" }).to include("format" => "count", "key_column" => true)
    expect(table["rows"]).to eq([["2026-11-22", 2, 2], ["2026-11-20", 1, 1]])
    expect(table["total"]).to eq(["Total", 3, nil])
  end

  it "has its example raise a plain message when the command fails" do
    expect { run_example(example.first, success: false) }
      .to raise_error(RuntimeError, "chi sessions list --scope=all --format json failed (exit 1)")
  end

  it "names only chi page subcommands and flags that exist" do
    commands = text.scan(/`chi page ([^`]+)`/).map(&:first)
    expect(commands).not_to be_empty
    commands.each do |line|
      sub, *rest = line.split
      expect(Samagotchi::PageCommand::SUBCOMMANDS).to include(sub), line
      flags = rest.select { |word| word.start_with?("--") }
      flags.each { |flag| expect(Samagotchi::PageCommand::USAGE).to include("#{sub} ").and include(flag) }
    end
    expect(commands.map { |line| line.split.first }.uniq).to match_array(Samagotchi::PageCommand::SUBCOMMANDS)
  end

  it "names only ui calls the builder has, with its keyword names" do
    calls = text.scan(/`ui\.(\w+)\(([^)]*)\)`/)
    expect(calls.map(&:first)).to match_array(%w[text table walk])
    builder = Samagotchi::Pages::Builder.instance_method(:table).parameters.map { |param| param.last.to_s }
    calls.to_h["table"].scan(/(\w+):/).flatten.each { |kw| expect(builder).to include(kw) }
    walk_keys = calls.to_h["walk"].scan(/(\w+):/).flatten
    expect(walk_keys).to eq(%w[title actors steps])
  end

  it "shows a walk step the walk schema takes" do
    step = text[/each step like\s+`(\{[^`]+\})`/, 1]
    expect(step).not_to be_nil
    data = { title: "t", actors: %w[dev ci], steps: [eval(step)] } # rubocop:disable Security/Eval -- the skill's own literal
    result = Samagotchi::InlineWidgets.check("walk", data)
    expect(result.error).to be_nil
  end

  it "states each limit as its constant in Pages" do
    expect(text[/(\d+) rows \(the rest are dropped/, 1].to_i).to eq(Samagotchi::Pages::MAX_ROWS)
    expect(text[/(\d+) columns, /, 1].to_i).to eq(Samagotchi::Pages::MAX_COLUMNS)
    expect(text[/(\d+) blocks, /, 1].to_i).to eq(Samagotchi::Pages::MAX_BLOCKS)
    expect(text[/blocks, (\d+) s\./, 1].to_i).to eq(Samagotchi::Pages::TIMEOUT_SECONDS)
    expect(text[/its first (\d+) rows/, 1].to_i).to eq(Samagotchi::PageCommand::TABLE_ROWS)
    expect(text).to include(*Samagotchi::Pages::FORMATS.map { |f| "`:#{f}`" })
  end
end
