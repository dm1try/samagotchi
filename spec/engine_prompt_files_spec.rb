# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/plugin/context"
require "tmpdir"

# The files whose text is in the session's system prompt (SystemPrompt#prompt_files):
# the appended ones come from Engine.new and reach /stats' snapshot.
RSpec.describe Samagotchi::Engine, "prompt files" do
  let(:tmp) { File.realpath(Dir.mktmpdir("engine-prompt-files")) }
  let(:registry) { Samagotchi::HostRegistry.new(hosts_config: { "box" => { host: "box.test", port: 8080 } }) }

  around { |example| with_config_home(tmp) { Dir.chdir(tmp) { example.run } } }
  after { FileUtils.remove_entry(tmp) }

  before { allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil) }

  it "puts --append-system-prompt's files into the prompt and names them in /stats" do
    file = File.join(tmp, "extra.md")
    File.write(file, "EXTRA RULES")
    engine = described_class.new(host_registry: registry, model_name: "box:gemma-small", profile: "gemma4",
                                 appended_prompt_files: [file])
    expect(engine.stats_snapshot[:prompt_files]).to eq([])

    expect(engine.system_prompt).to include("EXTRA RULES")
    expect(engine.stats_snapshot[:prompt_files]).to eq([file])
  end

  it "exposes the chain and appended files to plugins as ctx.prompt_files" do
    system("git", "-C", tmp, "init", "-q", exception: true)
    File.write(File.join(tmp, "AGENTS.md"), "ROOT RULES")
    FileUtils.mkdir_p(File.join(tmp, "pkg"))
    File.write(File.join(tmp, "pkg", "AGENTS.md"), "PKG RULES")
    extra = File.join(tmp, "extra.md")
    File.write(extra, "EXTRA RULES")

    engine = described_class.new(host_registry: registry, model_name: "box:gemma-small", profile: "gemma4",
                                 appended_prompt_files: [extra])
    ctx = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: engine.send(:plugin_host))
    Dir.chdir(File.join(tmp, "pkg")) do
      expect(ctx.prompt_files).to eq([]) # no prompt built yet

      expect(engine.system_prompt).to include("ROOT RULES", "PKG RULES", "EXTRA RULES")
      expect(ctx.prompt_files).to eq([File.join(tmp, "AGENTS.md"), File.join(tmp, "pkg", "AGENTS.md"), extra])
    end
  end
end
