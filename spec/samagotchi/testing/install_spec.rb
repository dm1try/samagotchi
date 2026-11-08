# frozen_string_literal: true

require "spec_helper"
require "digest"
require "tmpdir"
require "fileutils"
require "samagotchi/testing"

# Samagotchi::Testing::Install: a bundle installed as chi installs it and
# loaded by chi's own loaders, in the sandbox.
RSpec.describe Samagotchi::Testing::Install do
  let(:dir) { File.join(Dir.mktmpdir("kit-install-"), "greet") }
  let(:plugin) do
    <<~RUBY
      class Plugin
        def initialize(settings) = @word = settings.fetch("word", "hi")

        def register(chi)
          chi.command("/\#{@word}", "greets") { "hello" }
          chi.on(:after_tool_call, priority: 10) { |_event, _ctx| nil }
        end
      end
    RUBY
  end

  after { FileUtils.rm_rf(File.dirname(dir)) }

  def bundle(plugin, plugin_sha: nil, requires_chi: nil)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "plugin.rb"), plugin)
    manifest = "name: greet\nversion: 0.1.0\nplugin:\n  file: plugin.rb\n  " \
                "sha256: sha256:#{plugin_sha || Digest::SHA256.hexdigest(plugin)}\n"
    manifest << "requires_chi: \"#{requires_chi}\"\n" if requires_chi
    File.write(File.join(dir, "manifest.yml"), manifest)
  end

  def command(name) = described_class::Command.new(name: name, mid_turn: :refuse, labels: [])

  it "installs into the sandbox and returns what chi's loaders registered, with the bundle's settings" do
    bundle(plugin)
    Samagotchi::Testing::Sandbox.with do |_sandbox|
      result = described_class.run(dir, settings: { "word" => "yo" })

      expect(result).to have_attributes(name: "greet", warnings: [], plugin_failures: [], hook_failures: [], failures: [])
      expect(result.registered).to have_attributes(commands: [command("/yo")], tools: [], inits: [])
      expect(result.registered.hooks[:after_tool_call]).to eq([described_class::Hook.new(bundle: "greet", hook: "plugin.rb",
                                                                                         priority: 10)])
    end
  end

  it "names the source file and line where a plugin raised at load, not the installed copy" do
    bundle("class Plugin\n  def register(chi)\n    raise \"boom\"\n  end\nend\n")

    result = described_class.run(dir)

    expect(result.plugin_failures.map(&:to_h)).to contain_exactly(
      include(what: "plugin plugin.rb (bundle greet)", reason: "RuntimeError: boom", location: "#{dir}/plugin.rb:3")
    )
  end

  it "names a syntax error's line" do
    bundle("class Plugin\n  def register(chi)\n    chi.command(\n  end\nend\n")

    result = described_class.run(dir)

    expect(result.plugin_failures.first.location).to match(%r{\A#{Regexp.escape(dir)}/plugin\.rb:\d+\z})
    expect(result.hook_failures).to eq([])
  end

  it "returns the Installer's warnings: a stale sha" do
    bundle(plugin, plugin_sha: "0" * 64)

    result = described_class.run(dir)

    expect(result.warnings).to include(a_string_starting_with("Checksum mismatch for plugin plugin.rb"))
  end

  it "raises what the Installer refuses (a name chi ships), and installs it with force:" do
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "plugin.rb"), plugin)
    File.write(File.join(dir, "manifest.yml"),
               "name: btw\nversion: 0.1.0\nplugin:\n  file: plugin.rb\n  sha256: sha256:#{Digest::SHA256.hexdigest(plugin)}\n")

    expect { described_class.run(dir) }.to raise_error(Samagotchi::MemoryBundle::Installer::InstallError, /btw/)
    expect(described_class.run(dir, force: true).registered.commands).to eq([command("/hi")])
  end

  # A bundle whose requires_chi this chi doesn't meet is refused, as
  # `chi bundle install` refuses it; force: installs it and its plugin then
  # fails to load.
  it "refuses a bundle this chi is too old for, and installs it with force:" do
    bundle(plugin, requires_chi: ">= 99.0")

    expect { described_class.run(dir) }
      .to raise_error(Samagotchi::MemoryBundle::Installer::InstallError,
                      "greet can't be installed: it requires chi >= 99.0 (this is chi #{Samagotchi::VERSION}) " \
                      "(chi update, or --force to install it anyway)")

    result = described_class.run(dir, force: true)
    expect(result.warnings).to include(a_string_starting_with("Plugin plugin.rb won't load: it requires chi >= 99.0"))
    expect(result.plugin_failures.map(&:what)).to eq(["plugin plugin.rb (bundle greet)"])
    expect(result.registered.commands).to eq([])
  end

  it "is reached from a loaded bundle as Bundle#install" do
    bundle(plugin)
    Samagotchi::Testing::Sandbox.with do |sandbox|
      loaded = Samagotchi::Testing::Bundle.load(dir, settings: { "word" => "hey" }, sandbox: sandbox)
      expect(loaded.install.registered.commands).to eq([command("/hey")])
      loaded.shutdown
    end
  end
end
