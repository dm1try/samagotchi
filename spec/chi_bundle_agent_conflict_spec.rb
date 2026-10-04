# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"
require "stringio"
require "samagotchi/bundle_command"
require "samagotchi/terminal_ui"

# `chi bundle upgrade --agent` from an owned source (a zip): the conflict
# prompt hands the agent an incoming: path inside the extracted temp dir, so
# that dir must outlive the installer's #run until the agent step is done.
RSpec.describe "chi bundle upgrade --agent from a zip source" do
  let(:tmpdir) { Dir.mktmpdir("bundle-agent-conflict") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  after { FileUtils.rm_rf(tmpdir) }

  def make_bundle(dir, name:, version:, content:)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "a.md"), content)
    File.write(File.join(dir, "manifest.yml"), <<~YAML)
      name: #{name}
      version: #{version}
      scope: system
      files:
        a.md: sha256:#{Digest::SHA256.hexdigest(content)}
    YAML
    dir
  end

  def run(*argv) = Samagotchi::BundleCommand.new(argv, stdin: StringIO.new(""), stdout: out, stderr: err).run

  it "hands the agent an incoming file that still exists, then cleans the temp dir" do
    v1 = make_bundle(File.join(tmpdir, "v1"), name: "demo", version: "1.0.0", content: "one\n")
    run("install", v1)
    File.write(File.join(Samagotchi::MemoryPaths.system_dir, "a.md"), "edited\n")

    v2 = make_bundle(File.join(tmpdir, "v2"), name: "demo", version: "2.0.0", content: "two\n")
    zip = File.join(tmpdir, "v2.zip")
    Dir.chdir(v2) { system("zip", "-r", zip, ".") }

    seen = {}
    fake = Class.new do
      define_method(:initialize) do |prompt:|
        seen[:prompt] = prompt
        incoming = prompt[/incoming: (\S+)/, 1]
        seen[:incoming] = incoming
        seen[:existed] = incoming && File.exist?(incoming)
        seen[:content] = incoming && File.exist?(incoming) ? File.read(incoming) : nil
      end
      define_method(:run) { nil }
    end
    stub_const("Samagotchi::TerminalUI", fake)

    code = run("upgrade", zip, "--agent")

    expect(code).to eq(0)
    expect(seen[:incoming]).not_to be_nil
    expect(seen[:existed]).to be(true)
    expect(seen[:content]).to eq("two\n")
    # The temp dir is gone once the agent step is done.
    expect(File.exist?(seen[:incoming])).to be(false)
  end

  it "removes the extracted temp dir when the upgrade fails before the agent step" do
    v1 = make_bundle(File.join(tmpdir, "v1"), name: "demo", version: "1.0.0", content: "one\n")
    run("install", v1)
    File.write(File.join(Samagotchi::MemoryPaths.system_dir, "a.md"), "edited\n")

    v2 = make_bundle(File.join(tmpdir, "v2"), name: "demo", version: "2.0.0", content: "two\n")
    zip = File.join(tmpdir, "v2.zip")
    Dir.chdir(v2) { system("zip", "-r", zip, ".") }

    extracted = []
    allow(Samagotchi::MemoryBundle::SourceNormalizer).to receive(:normalize).and_wrap_original do |original, *args|
      original.call(*args).tap { |dir, owned, _commit| extracted << dir if owned }
    end
    command = Samagotchi::BundleCommand.new(["upgrade", zip, "--agent"], stdin: StringIO.new(""), stdout: out, stderr: err)
    allow(command).to receive(:print_hooks_and_plugin).and_raise(IOError, "stdout closed")

    expect { command.run }.to raise_error(IOError)
    # The bundle name is read from its own extraction; the installer's is the last.
    expect(extracted).not_to be_empty
    expect(extracted.select { |dir| File.exist?(dir) }).to eq([])
  end
end
