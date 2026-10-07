# frozen_string_literal: true

require "samagotchi/engine"
require "tmpdir"

# Model notes (ModelNotes) in the system prompt: their own section right
# after identity in both loops, the matching ones only, without their
# index lines; the identity overlay still loads, and a prompt without
# notes is what it was.
RSpec.describe "System prompt model notes" do
  let(:tmp) { Dir.mktmpdir("prompt-model-notes") }
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { host: "box.test", port: 8080 },
      "oai" => { host: "oai.test", port: 8000, api: :openai }
    })
  end
  let(:dir) { Samagotchi::MemoryPaths.system_dir }

  around { |example| with_config_home(tmp) { example.run } }
  after { FileUtils.remove_entry(tmp) }

  before do
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "identity.md"), "BASE IDENTITY\n")
    File.write(File.join(dir, "identity.gemma-small.md"), "GEMMA IDENTITY OVERLAY\n")
    File.write(File.join(dir, "foo.md"), "BASE FOO\n")
    File.write(File.join(dir, "index.md"), "- **foo** · 9 B · foo\n- **model_notes_gemma** · 30 B · gemma habits\n")
  end

  def note(name, text) = File.write(File.join(dir, "#{name}.md"), text)

  def engine(model, **opts)
    Samagotchi::Engine.new(host_registry: registry, model_name: model, profile: "gemma4", memories: ["system/foo"], **opts)
  end

  it "puts the matching notes after identity and before the preloads, in both loops" do
    note("model_notes_gemma", "models: gemma-*\nGEMMA NOTE\n")
    note("model_notes_other", "models: qwen*\nQWEN NOTE\n")

    %w[box:gemma-small oai:gemma-small].each do |model|
      prompt = engine(model).system_prompt
      section = "Model notes (for #{model}, scope=system):\n\n## model_notes_gemma\nGEMMA NOTE"
      expect(prompt).to include(section)
      expect(prompt.index("GEMMA IDENTITY OVERLAY")).to be < prompt.index(section)
      expect(prompt.index(section)).to be < prompt.index("BASE FOO")
      expect(prompt).not_to include("QWEN NOTE", "models: gemma-*")
    end
  end

  it "stacks the system scope's notes, then the project's, each scope under its own heading" do
    project = Samagotchi::MemoryPaths.project_dir
    FileUtils.mkdir_p(project)
    File.write(File.join(project, "model_notes_a.md"), "models: gemma-*\nPROJECT A\n")
    note("model_notes_b", "models: *\nSYSTEM B\n")
    note("model_notes_a", "models: small|gemma-*\nSYSTEM A\n")

    prompt = engine("box:gemma-small").system_prompt
    system = "Model notes (for box:gemma-small, scope=system):\n\n## model_notes_a\nSYSTEM A\n\n## model_notes_b\nSYSTEM B"
    project_section = "Model notes (for box:gemma-small, scope=project):\n\n## model_notes_a\nPROJECT A"
    expect(prompt).to include("#{system}\n\n#{project_section}\n")
  end

  it "keeps the index line of a model_notes_ memory that isn't a note (no models: line)" do
    note("model_notes_todo", "my plain notes\n")
    File.write(File.join(dir, "index.md"), "- **model_notes_todo** · 15 B · todo list\n")
    expect(engine("box:gemma-small").system_prompt).to include("- **model_notes_todo** · 15 B · todo list")
  end

  it "leaves the notes' index lines out of the prompt's index" do
    note("model_notes_gemma", "models: gemma-*\nGEMMA NOTE\n")
    prompt = engine("box:qwen3").system_prompt
    expect(prompt).to include("- **foo** · 9 B · foo")
    expect(prompt).not_to include("model_notes_gemma", "GEMMA NOTE")
  end

  it "drops a muted note and keeps it when identity is muted" do
    note("model_notes_gemma", "models: gemma-*\nGEMMA NOTE\n")
    expect(engine("box:gemma-small", muted_memories: ["model_notes_gemma"]).system_prompt).not_to include("GEMMA NOTE")

    prompt = engine("box:gemma-small", muted_memories: ["identity"]).system_prompt
    expect(prompt).to include("GEMMA NOTE")
    expect(prompt).not_to include("BASE IDENTITY")
  end

  it "follows a model switch" do
    note("model_notes_gemma", "models: gemma-*\nGEMMA NOTE\n")
    e = engine("box:gemma-small")
    expect(e.system_prompt).to include("GEMMA NOTE")
    e.switch_model!("oai:m")
    expect(e.system_prompt).not_to include("GEMMA NOTE", "Model notes")
  end

  it "is the same prompt as before without a note" do
    without = engine("box:gemma-small").system_prompt
    note("model_notes_other", "models: qwen*\nQWEN NOTE\n")
    expect(engine("box:gemma-small").system_prompt).to eq(without)
  end
end
