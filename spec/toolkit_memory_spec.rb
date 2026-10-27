# frozen_string_literal: true

require "spec_helper"
require "samagotchi/toolkit_binding"
require "samagotchi/toolkit_command"

RSpec.describe Samagotchi::ToolkitBinding, "memory kits" do
  let(:working_directory) { Dir.mktmpdir("toolkit-memory-project") }
  let(:session) { double(working_directory: working_directory, muted_memory_names: []) }
  let(:config_kits) { {} }
  let(:binding) do
    described_class.new(tools: -> {}, session: -> { session }, state_dir: -> {}, can_stage: -> { true },
                        reset_prompt: -> {}, emit: ->(*) {}, notify: ->(*) {})
  end

  around do |example|
    home = Dir.mktmpdir("toolkit-memory-config")
    with_config_home(home) { example.run }
  ensure
    FileUtils.rm_rf(home) if home
  end

  before do
    allow(Samagotchi::Toolkit).to receive(:config_kits).and_return(config_kits)
  end

  after do
    FileUtils.rm_rf(working_directory)
  end

  def write_memory(scope, filename, content)
    dir = Samagotchi::MemoryPaths.scope_dir(scope, cwd: working_directory)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, filename), content)
  end

  def memory(description, **values)
    YAML.dump(values.transform_keys(&:to_s).merge("description" => description))
      .then { |yaml| "```yaml\n#{yaml}```\n" }
  end

  it "loads project and system kits from their memory names with scoped sources" do
    write_memory("project", "toolkit_project.md", memory("Project work", base: "lean", add: %w[read]))
    write_memory("system", "toolkit_system.md", memory("System work", base: "lean", add: %w[web_fetch]))

    kits = binding.kits

    expect(kits.fetch("project").source).to eq("memory:project")
    expect(kits.fetch("project").description).to eq("Project work")
    expect(kits.fetch("system").source).to eq("memory:system")
    expect(kits.fetch("system").description).to eq("System work")
  end

  it "finds the project's kits once the session exists, after a call made before it" do
    current = nil
    early = described_class.new(tools: -> {}, session: -> { current }, state_dir: -> {}, can_stage: -> { true },
                                reset_prompt: -> {}, emit: ->(*) {}, notify: ->(*) {})
    write_memory("project", "toolkit_local.md", memory("Local kit", base: "lean"))

    expect(early.kits).not_to have_key("local")
    current = session
    expect(early.kits.fetch("local").source).to eq("memory:project")
  end

  it "uses the session working directory and caches memory kits for the worker" do
    write_memory("project", "toolkit_local.md", memory("Local kit", base: "lean"))
    kits = binding.kits
    write_memory("project", "toolkit_local.md", memory("Changed kit", base: "full"))

    expect(binding.kits.fetch("local").description).to eq("Local kit")
    expect(kits.fetch("local").base).to eq("lean")
  end

  it "skips model overlays and muted memory kits" do
    write_memory("project", "toolkit_hidden.md", memory("Hidden kit", base: "lean"))
    write_memory("project", "toolkit_hidden.qwen3.md", memory("Overlay", base: "full"))
    allow(session).to receive(:muted_memory_names).and_return(["project/toolkit_hidden.md"])

    kits = binding.kits

    expect(kits).not_to have_key("hidden")
    expect(kits).not_to have_key("hidden.qwen3")
  end

  it "keeps config and bundle kits ahead of memory kits, with project ahead of system" do
    allow(Samagotchi::Toolkit).to receive(:config_kits)
      .and_return("configured" => { "base" => "lean", "add" => ["delegate"] },
                  "config_wins" => { "base" => "lean" })
    binding.plugin_kits << Samagotchi::Toolkit::Kit.new(name: "bundle_wins", base: "lean", source: "sample-bundle")
    write_memory("project", "toolkit_work.md", memory("Work", base: "configured", add: ["web_fetch"]))
    write_memory("project", "toolkit_config_wins.md", memory("Ignored config collision", base: "full"))
    write_memory("project", "toolkit_bundle_wins.md", memory("Ignored bundle collision", base: "full"))
    write_memory("project", "toolkit_review.md", memory("Reserved kit name", base: "full"))
    write_memory("project", "toolkit_scope_wins.md", memory("Project scope", base: "lean"))
    write_memory("system", "toolkit_scope_wins.md", memory("System scope", base: "full"))
    errors = []

    kits = binding.kits(errors)
    resolved = Samagotchi::Toolkit.resolve_kit("work", kits)

    expect(kits.fetch("configured").source).to eq("config")
    expect(kits.fetch("bundle_wins").source).to eq("sample-bundle")
    expect(kits.fetch("review").source).to eq("core")
    expect(kits.fetch("scope_wins").source).to eq("memory:project")
    expect(resolved.added).to contain_exactly("delegate", "web_fetch")
    expect(errors).to include(a_string_including("toolkit_config_wins", "already defined"),
                              a_string_including("toolkit_bundle_wins", "already defined"),
                              a_string_including("toolkit_review", "already defined"),
                              a_string_including("toolkit_scope_wins", "already defined"))
  end

  it "warns once for malformed blocks, missing descriptions, and refused prompt keys" do
    write_memory("project", "toolkit_broken.md", "not a fenced yaml block")
    write_memory("project", "toolkit_missing_description.md", "```yaml\nbase: lean\n```\n")
    write_memory("project", "toolkit_prompt.md", "```yaml\nbase: lean\nprompt: nope\n" \
                                                  "description: Refused\n```\n")
    write_memory("project", "toolkit_bad_description.md", memory("x" * 301, base: "lean"))
    errors = []

    kits = binding.kits(errors)

    %w[broken missing_description prompt bad_description].each do |name|
      expect(kits).not_to have_key(name)
    end
    expect(errors.size).to eq(4)
    expect(errors.map { |line| line[/toolkit_[a-z_]+/] }).to contain_exactly(
      "toolkit_broken", "toolkit_missing_description", "toolkit_prompt", "toolkit_bad_description"
    )
    expect(errors).to include(a_string_including("prompt", "not supported"))
  end

  it "shows a memory kit's source in the /toolkit listing" do
    write_memory("project", "toolkit_project.md", memory("Project work", base: "lean"))
    kits = binding.kits
    resolved = Samagotchi::Toolkit::Resolved.new(name: "full")
    explained = Samagotchi::Toolkit::Explained.new(toolkit: Samagotchi::Toolkit.new(name: "full"),
                                                   resolved: resolved, declared: [], left_out: [], pending: false)
    engine = double(toolkit_kits: kits, toolkit_explained: explained)
    command = Samagotchi::ToolkitCommand.new(engine: engine, save: ->(*) {})

    expect(command.listing(explained)).to include("toolkits: full, lean, child, review, project (memory:project);")
  end
end
