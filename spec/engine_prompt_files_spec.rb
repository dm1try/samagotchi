# frozen_string_literal: true

require "samagotchi/engine"
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
end
