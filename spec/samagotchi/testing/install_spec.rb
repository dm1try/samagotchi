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

  def bundle(plugin, hook: nil, plugin_sha: nil)
    FileUtils.mkdir_p(File.join(dir, "hooks"))
    File.write(File.join(dir, "plugin.rb"), plugin)
    manifest = "name: greet\nversion: 0.1.0\nplugin:\n  file: plugin.rb\n  " \
                "sha256: sha256:#{plugin_sha || Digest::SHA256.hexdigest(plugin)}\n"
    if hook
      File.write(File.join(dir, "hooks", "h.rb"), hook)
      manifest << "hooks:\n  h.rb:\n    sha256: sha256:#{Digest::SHA256.hexdigest(hook)}\n    event: after_turn\n"
    end
    File.write(File.join(dir, "manifest.yml"), manifest)
  end

  it "installs into the sandbox and returns what chi's loaders registered, with the bundle's settings" do
    bundle(plugin)
    Samagotchi::Testing::Sandbox.with do |_sandbox|
      result = described_class.run(dir, settings: { "word" => "yo" })

      expect(result).to have_attributes(name: "greet", warnings: [], plugin_failures: [], hook_failures: [], ok?: true)
      expect(result.registered).to include(commands: [["/yo", :refuse, []]], tools: [], inits: [])
      expect(result.registered[:hooks][:after_tool_call]).to eq([["greet", "plugin.rb", 10]])
    end
  end

  it "names the source file and line where a plugin raised at load, not the installed copy" do
    bundle("class Plugin\n  def register(chi)\n    raise \"boom\"\n  end\nend\n")

    result = described_class.run(dir)

    expect(result.plugin_failures.map(&:to_h)).to contain_exactly(
      include(what: "plugin plugin.rb (bundle greet)", reason: "RuntimeError: boom", location: "#{dir}/plugin.rb:3")
    )
  end

  it "names a syntax error's line, and a hook file's" do
    bundle("class Plugin\n  def register(chi)\n    chi.command(\n  end\nend\n",
           hook: "class H\n  def initialize\n    nil.boom\n  end\nend\n")

    result = described_class.run(dir)

    expect(result.plugin_failures.first.location).to match(%r{\A#{Regexp.escape(dir)}/plugin\.rb:\d+\z})
    expect(result.hook_failures.map(&:location)).to eq(["#{dir}/hooks/h.rb:3"])
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
    expect(described_class.run(dir, force: true).registered[:commands]).to eq([["/hi", :refuse, []]])
  end

  it "is reached from a loaded bundle as Bundle#install" do
    bundle(plugin)
    Samagotchi::Testing::Sandbox.with do |sandbox|
      loaded = Samagotchi::Testing::Bundle.load(dir, settings: { "word" => "hey" }, sandbox: sandbox)
      expect(loaded.install.registered[:commands]).to eq([["/hey", :refuse, []]])
      loaded.shutdown
    end
  end
end
