# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/hooks"
require "samagotchi/bundle_command"
require "samagotchi/tools/execute"

# docs/bundle-authoring.md, the first thing chi reads to write a bundle
# (self_map points to it): one read with no cut, every hook event named, the
# commands it names real, and its execute sample in Tools::Execute's format.
RSpec.describe "docs/bundle-authoring.md" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:doc) { File.read(File.join(root, "docs/bundle-authoring.md")) }

  it "stays one read: 150 lines at most" do
    expect(doc.lines.size).to be <= 150
  end

  it "names every hook event" do
    expect(Samagotchi::Hooks::EVENTS.reject { |event| doc.include?("`#{event}`") }).to eq([])
  end

  it "names only chi bundle subcommands that exist" do
    named = doc.scan(/chi bundle ([a-z]+)/).flatten.uniq
    usage = Samagotchi::BundleCommand::USAGE[/<([a-z|]+)>/, 1].split("|")
    expect(named).to include("new", "test", "check", "install")
    expect(named - usage).to eq([])
  end

  it "shows an execute result: as Tools::Execute renders one" do
    sample = doc[/result: "(stdout:.*?exit: 1)"/, 1].gsub("\\n", "\n")
    real = Dir.mktmpdir { |dir| Samagotchi::Tools::Execute.call("echo ok; echo '1 failed' >&2; exit 1", cwd: dir) }
    expect(sample).to eq(real)
    expect(doc).to include("`exit: 0 (no output)`")
    expect(Dir.mktmpdir { |dir| Samagotchi::Tools::Execute.call("true", cwd: dir) }).to eq("exit: 0 (no output)")
  end

  it "is what self_map points to for writing a bundle" do
    expect(File.read(File.join(root, "lib/samagotchi/bundles/system/self_map.md")).gsub(/\s+/, " "))
      .to include("Writing one: read `docs/bundle-authoring.md` in my source dir first.")
  end
end
