# frozen_string_literal: true

require "samagotchi/engine"
require "tmpdir"

# The prompt's own memory bodies (the identity and the preloads) get their
# model overlays as memory_read gives them: `<name>.<key>.md` appended under
# the matching model only, and the rebuilt prompt follows a switch.
RSpec.describe "System prompt memories with model overlays" do
  let(:tmp) { Dir.mktmpdir("prompt-overlays") }
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { host: "box.test", port: 8080 },
      "oai" => { host: "oai.test", port: 8000, api: :openai }
    })
  end

  around { |example| with_config_home(tmp) { example.run } }
  after { FileUtils.remove_entry(tmp) }

  before do
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
    dir = Samagotchi::MemoryPaths.system_dir
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "identity.md"), "BASE IDENTITY\n")
    File.write(File.join(dir, "identity.gemma-small.md"), "GEMMA IDENTITY OVERLAY\n")
    File.write(File.join(dir, "foo.md"), "BASE FOO\n")
    File.write(File.join(dir, "foo.gemma-small.md"), "GEMMA FOO OVERLAY\n")
    File.write(File.join(dir, "foo.m.md"), "M FOO OVERLAY\n")
  end

  def engine(model, **opts)
    Samagotchi::Engine.new(host_registry: registry, model_name: model, profile: "gemma4", memories: ["system/foo"], **opts)
  end

  it "appends the identity and preload overlays of the session's model only" do
    prompt = engine("box:gemma-small").system_prompt
    expect(prompt).to include("BASE IDENTITY", "GEMMA IDENTITY OVERLAY", "BASE FOO", "GEMMA FOO OVERLAY")
    expect(prompt).not_to include("M FOO OVERLAY")

    other = engine("oai:m").system_prompt
    expect(other).to include("BASE IDENTITY", "BASE FOO", "M FOO OVERLAY")
    expect(other).not_to include("GEMMA IDENTITY OVERLAY", "GEMMA FOO OVERLAY")
  end

  it "follows a model switch" do
    e = engine("box:gemma-small")
    expect(e.system_prompt).to include("GEMMA FOO OVERLAY")
    e.switch_model!("oai:m")
    expect(e.system_prompt).to include("M FOO OVERLAY")
    expect(e.system_prompt).not_to include("GEMMA FOO OVERLAY", "GEMMA IDENTITY OVERLAY")
  end
end
