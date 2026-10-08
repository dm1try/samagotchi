# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "tmpdir"

# The model notes a session's prompt carried (Session#prompt_notes): set
# at each prompt build (a resume's first build too) and on /model, saved
# with the session, carried by the state snapshot and /stats' snapshot.
RSpec.describe Samagotchi::Engine, "prompt notes" do
  let(:tmp) { Dir.mktmpdir("engine-prompt-notes") }
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { host: "box.test", port: 8080 },
      "oai" => { host: "oai.test", port: 8000, api: :openai }
    })
  end
  let(:dir) { Samagotchi::MemoryPaths.system_dir }
  let(:gemma) do
    { name: "model_notes_gemma", scope: "system", chars: 10,
      digest: Digest::SHA256.hexdigest("GEMMA NOTE")[0, 12] }
  end

  around { |example| with_config_home(tmp) { example.run } }
  after { FileUtils.remove_entry(tmp) }

  before do
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "model_notes_gemma.md"), "models: gemma-*\nGEMMA NOTE\n")
    File.write(File.join(dir, "model_notes_qwen.md"), "models: qwen*\nQWEN NOTE\n")
  end

  def engine(model, **opts)
    described_class.new(host_registry: registry, model_name: model, profile: "gemma4", **opts)
  end

  def new_session(model) = Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: tmp)

  it "records the notes a build carries on the session, the state snapshot and /stats' snapshot" do
    e = engine("box:gemma-small")
    e.session = new_session("box:gemma-small")
    expect(e.session_state_snapshot[:prompt_notes]).to eq([gemma])

    e.system_prompt

    expect(e.session.prompt_notes).to eq([Samagotchi::PromptNote.new(**gemma)])
    expect(e.session_state_snapshot[:prompt_notes]).to eq([gemma])
    expect(e.stats_snapshot[:prompt_notes]).to eq([gemma])
  end

  it "names the notes the effective model's prompt will load on a fresh session, before any build" do
    e = engine("box:gemma-small")
    e.session = new_session("box:gemma-small")

    expect(e.prompt_notes.map(&:name)).to eq(%w[model_notes_gemma])
    # The row is recomputed; the session file keeps its shape ([] until a build).
    expect(e.session.prompt_notes).to eq([])
  end

  it "leaves a muted note out of a fresh session's prompt notes" do
    e = engine("box:gemma-small", muted_memories: ["model_notes_gemma"])
    e.session = new_session("box:gemma-small")

    expect(e.prompt_notes).to eq([])
  end

  it "keeps a session's saved [] when a turn ran and its prompt carried none" do
    e = engine("box:gemma-small")
    e.session = new_session("box:gemma-small")
    e.session.messages = [{ role: "user", content: "hi" }]

    expect(e.prompt_notes).to eq([])
  end

  it "keeps a resumed session's saved notes until its prompt is built again, then records the new ones" do
    session = new_session("box:gemma-small")
    session.prompt_notes = [{ "name" => "model_notes_old", "scope" => "system", "chars" => 3, "digest" => "abc" }]
    session.save

    e = engine("box:gemma-small", session_id: session.id)
    expect(e.session_state_snapshot[:prompt_notes]).to eq([{ name: "model_notes_old", scope: "system", chars: 3,
                                                             digest: "abc" }])

    e.system_prompt
    expect(e.session_state_snapshot[:prompt_notes]).to eq([gemma])

    e.session.save
    expect(Samagotchi::Session.load(session.id).prompt_notes).to eq([Samagotchi::PromptNote.new(**gemma)])
  end

  it "records a muted note as not carried" do
    e = engine("box:gemma-small", muted_memories: ["model_notes_gemma"])
    e.session = new_session("box:gemma-small")
    e.system_prompt
    expect(e.session.prompt_notes).to eq([])
  end

  it "records the new model's notes on /model, before the next build" do
    e = engine("box:gemma-small")
    e.session = new_session("box:gemma-small")
    e.system_prompt

    e.switch_model!("box:qwen3")
    expect(e.session.prompt_notes.map(&:name)).to eq(%w[model_notes_qwen])

    e.switch_model!("oai:m")
    expect(e.session_state_snapshot[:prompt_notes]).to eq([])
  end

  it "names the notes the model's prompt would load when there is no session" do
    expect(engine("box:gemma-small").prompt_notes.map(&:name)).to eq(%w[model_notes_gemma])
  end
end
