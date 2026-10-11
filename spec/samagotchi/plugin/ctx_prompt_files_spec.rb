# frozen_string_literal: true

require "spec_helper"
require "samagotchi/plugin/context"

# ctx.prompt_files (docs/plugins.md, Context): the files whose text the
# session's system prompt holds now, from the Engine's host.
RSpec.describe "ctx.prompt_files" do
  def ctx(host)
    Samagotchi::Plugin::Context.new(bundle: "agents-md", label: "plugin.rb (bundle agents-md)", settings: {}, host: host)
  end

  it "returns the host's list, frozen" do
    host = Samagotchi::Plugin::Host.new(prompt_files: -> { %w[/repo/AGENTS.md /repo/pkg/AGENTS.md] })
    expect(ctx(host).prompt_files).to eq(%w[/repo/AGENTS.md /repo/pkg/AGENTS.md])
    expect(ctx(host).prompt_files.frozen?).to be(true)
  end

  it "re-reads the host each time, so a rebuild shows at once" do
    files = []
    host = Samagotchi::Plugin::Host.new(prompt_files: -> { files.dup })
    expect(ctx(host).prompt_files).to eq([])
    files << "/repo/AGENTS.md"
    expect(ctx(host).prompt_files).to eq(["/repo/AGENTS.md"])
  end

  it "is [] for a host without the member, and for a host whose callable says so" do
    expect(ctx(Samagotchi::Plugin::Host.new).prompt_files).to eq([])
    expect(ctx(Samagotchi::Plugin::Host.new(prompt_files: -> { nil })).prompt_files).to eq([])
  end
end
