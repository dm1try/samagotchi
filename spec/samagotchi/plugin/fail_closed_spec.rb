# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"
require "samagotchi/engine"
require "samagotchi/memory_bundle/installer"
require "samagotchi/testing"

# chi.on(:before_tool_call, on_error: :fail_closed) and the manifest's
# plugin: required: true (docs/hooks.md, docs/guardrails.md "Failing
# closed"): a fail-closed hook that raises denies the call, and a required
# plugin that fails to load denies every call.
RSpec.describe "A fail-closed plugin hook" do
  let(:tmpdir) { Dir.mktmpdir("plugin-fail-closed-") }
  let(:client) { instance_double(Samagotchi::Client, complete: nil) }
  let(:guard) do
    <<~RUBY
      class Plugin
        def register(chi)
          chi.on(:before_tool_call, priority: 10, on_error: :fail_closed) do |event, _ctx|
            raise "guard broke" if event[:call][:content].to_s.include?("boom")
          end
        end
      end
    RUBY
  end

  after { FileUtils.rm_rf(tmpdir) }

  # A bundle source dir +name+ whose plugin.rb is +source+, its manifest's
  # plugin: required: +required+ (left out when nil).
  def source_dir(name, source, required: true, requires_chi: nil)
    src = File.join(tmpdir, "src-#{name}")
    FileUtils.mkdir_p(src)
    File.write(File.join(src, "plugin.rb"), source)
    plugin = { "file" => "plugin.rb", "sha256" => "sha256:#{Digest::SHA256.hexdigest(source)}" }
    plugin["required"] = required unless required.nil?
    manifest = { "name" => name, "version" => "1.0.0", "files" => {}, "plugin" => plugin }
    manifest["requires_chi"] = requires_chi if requires_chi
    File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))
    src
  end

  describe "chi.on's on_error:" do
    let(:api) { Samagotchi::Plugin::Api.new(bundle: "b", label: "plugin.rb (bundle b)", registries: Samagotchi::Plugin::Registries.new) }

    it "takes :fail_closed for :before_tool_call only" do
      expect { api.on(:after_turn, on_error: :fail_closed) { nil } }
        .to raise_error(ArgumentError, "on(:after_turn): on_error: :fail_closed is for :before_tool_call only")
      expect { api.on(:before_tool_call, on_error: :skip) { nil } }
        .to raise_error(ArgumentError, "on(:before_tool_call): on_error: must be :log or :fail_closed, not :skip")
      api.on(:before_tool_call, on_error: "fail_closed") { nil }
      expect(api.fail_closed?).to be(true)
    end

    it "is :log by default: the plugin is no guardrail" do
      api.on(:before_tool_call) { nil }
      expect(api.fail_closed?).to be(false)
    end
  end

  describe "through the bundle test kit" do
    around { |example| Samagotchi::Testing::Sandbox.with { example.run } }

    def call(content) = { name: "execute", content: content }

    it "denies the call it raises on, naming the guard; a call it lets through runs" do
      bundle = Samagotchi::Testing::Bundle.load(source_dir("guard", guard))
      verdict = bundle.lenient { bundle.tool_call(call("echo boom")) }
      expect(verdict).to be_deny
      expect(verdict.reason).to include("guardrail plugin.rb (bundle guard) before_tool_call hook raised RuntimeError: guard broke")
      expect(bundle.errors.map(&:hook)).to eq(["guardrail plugin.rb (bundle guard) before_tool_call hook"])
      expect(bundle.tool_call(call("echo fine"))).to be_allow
    ensure
      bundle&.shutdown
    end

    it "leaves a :log hook that raises to log: the call runs" do
      bundle = Samagotchi::Testing::Bundle.load(source_dir("guard", guard.sub(", on_error: :fail_closed", ""), required: nil))
      expect(bundle.lenient { bundle.tool_call(call("echo boom")) }).to be_allow
    ensure
      bundle&.shutdown
    end
  end

  describe "an installed plugin at Engine start" do
    let(:system_dir) { Samagotchi::MemoryPaths.system_dir }

    around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
    around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

    before do
      FileUtils.mkdir_p(system_dir)
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    end

    def install(name, source, **)
      src = source_dir(name, source, **)
      requires = YAML.load_file(File.join(src, "manifest.yml")).key?("requires_chi")
      Samagotchi::MemoryBundle::Installer.new(source: src, name: name, scope: "system", strict: true, force: requires).run
      File.join(system_dir, ".bundles", name, "plugin", "plugin.rb")
    end

    def started
      eng = nil
      expect { eng = Samagotchi::Engine.new(client: client) }.to output.to_stderr
      eng
    end

    def denied_reason(eng)
      verdict = Samagotchi::Guardrails::Verdict.new(call: { name: "read", path: "x" })
      eng.guardrail_failures.check(verdict)
      verdict.deny? ? verdict.reason : nil
    end

    it "loads a required plugin as any other: nothing is denied" do
      install("guard", guard)
      eng = Samagotchi::Engine.new(client: client)
      expect([eng.guardrail_failures.list, eng.plugin_failures.list]).to eq([[], []])
      expect(eng.instance_variable_get(:@hooks).bundle_hook_names(:before_tool_call)).to eq([["guard", "plugin.rb", 10]])
    end

    it "denies every tool call when a required plugin's file no longer has its sha" do
      path = install("guard", guard)
      File.write(path, guard.sub("guard broke", "tampered"))
      eng = started
      failure = eng.guardrail_failures.required.first
      expect(failure.what).to eq("plugin plugin.rb (bundle guard)")
      expect(failure.reason).to include("sha256")
      expect(eng.plugin_failures.any?).to be(false)
      expect(denied_reason(eng)).to start_with("required guardrail plugin plugin.rb (bundle guard) failed to load")
      expect(eng.guardrail_failures.message).to include("Every tool call is denied")
    end

    it "denies every tool call when chi doesn't meet a required plugin's requires_chi" do
      install("guard", guard, requires_chi: ">= 99.0")
      expect(denied_reason(started)).to include("requires chi >= 99.0")
    end

    it "denies every tool call when a required plugin raises before it registers anything" do
      install("guard", "raise 'broken at load'\n")
      expect(denied_reason(started)).to include("RuntimeError: broken at load")
    end

    it "still denies when the kept manifest.yml is gone too: the record says required" do
      path = install("guard", guard)
      FileUtils.rm_f(File.join(system_dir, ".bundles", "guard", "manifest.yml"))
      File.write(path, guard.sub("guard broke", "tampered"))
      expect(denied_reason(started)).to include("sha256")
    end

    it "still denies when the kept manifest.yml was edited to drop the flag" do
      path = install("guard", guard)
      kept = File.join(system_dir, ".bundles", "guard", "manifest.yml")
      File.write(kept, File.read(kept).sub("required: true", "required: false"))
      File.write(path, guard.sub("guard broke", "tampered"))
      expect(denied_reason(started)).to include("sha256")
    end

    it "denies every tool call when the plugin's folder is gone" do
      path = install("guard", guard)
      FileUtils.rm_rf(File.dirname(path))
      expect(denied_reason(started)).to include("the file is missing")
    end

    it "denies every tool call when #register raises (after staging the guard)" do
      install("guard", guard.sub("    end\n  end\nend", "    end\n    raise \"half way\"\n  end\nend"))
      expect(denied_reason(started)).to include("RuntimeError: half way")
    end

    it "keeps a plugin without required: as today: its load failure denies nothing" do
      path = install("guard", guard, required: nil)
      File.write(path, "# tampered\n")
      eng = started
      expect(eng.guardrail_failures.any?).to be(false)
      expect(eng.plugin_failures.list.map(&:required)).to eq([false])
    end

    it "logs a fail-closed hook whose manifest doesn't say required: it loads and guards" do
      install("guard", guard, required: nil)
      allow(Samagotchi::Log).to receive(:warn).and_call_original
      eng = Samagotchi::Engine.new(client: client)
      expect(eng.plugin_failures.any?).to be(false)
      expect(Samagotchi::Log).to have_received(:warn).with(:plugins, "plugin_fail_closed_unrequired", hash_including(bundle: "guard"))
    end
  end
end
