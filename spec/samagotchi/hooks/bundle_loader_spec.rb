# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "digest"
require "samagotchi/hooks/bundle_loader"
require "samagotchi/hooks/registry"
require "samagotchi/guardrails"

RSpec.describe Samagotchi::Hooks::BundleLoader do
  let(:tmpdir) { Dir.mktmpdir("bundle-loader-") }
  after { FileUtils.rm_rf(tmpdir) }

  def write_hook(dir, basename, content)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, basename), content)
  end

  describe ".load" do
    it "loads and registers a hook" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "guardrails.rb", "class Guardrails; def call(e); e[:called]=true; end; end")
      registry = Samagotchi::Hooks::Registry.new
      sha = Digest::SHA256.hexdigest(File.read(File.join(hooks_dir, "guardrails.rb")))
      metadata = { "guardrails.rb" => { "event" => "before_tool_call", "on_error" => "skip", "priority" => 10, "sha256" => "sha256:#{sha}" } }
      loaded = described_class.load(bundle_name: "test-bundle", hooks_dir: hooks_dir, metadata: metadata, registry: registry)
      expect(loaded).to eq(1)
      expect(registry.size).to eq(1)
      e = {}
      registry.fire(:before_tool_call, e)
      expect(e[:called]).to be true
    end

    it "gives a hook whose initialize takes an argument the bundle's settings, and builds the others bare" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "with_settings.rb", "class WithSettings; def initialize(s = {}); @s = s; end; def call(e); e[:settings] = @s; end; end")
      write_hook(hooks_dir, "bare.rb", "class Bare; def call(e); e[:bare] = true; end; end")
      registry = Samagotchi::Hooks::Registry.new
      meta = { "with_settings.rb" => { "event" => "before_turn" }, "bare.rb" => { "event" => "before_turn" } }
      loaded = described_class.load(bundle_name: "settings-bundle", hooks_dir: hooks_dir, metadata: meta, registry: registry,
                                    settings: { "names" => ["x"], "mode" => "ask" })
      expect(loaded).to eq(2)
      e = {}
      registry.fire(:before_turn, e)
      expect(e).to include(settings: { "names" => ["x"], "mode" => "ask" }, bare: true)
    end

    it "gives a hook an empty settings hash when the bundle has none configured" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "with_settings.rb", "class WithSettings; def initialize(s); @s = s; end; def call(e); e[:settings] = @s; end; end")
      registry = Samagotchi::Hooks::Registry.new
      described_class.load(bundle_name: "no-settings", hooks_dir: hooks_dir, metadata: { "with_settings.rb" => { "event" => "before_turn" } }, registry: registry)
      e = {}
      registry.fire(:before_turn, e)
      expect(e[:settings]).to eq({})
    end

    it "isolates same basename across two bundles via namespacing" do
      dir1 = File.join(tmpdir, "b1", "hooks")
      dir2 = File.join(tmpdir, "b2", "hooks")
      write_hook(dir1, "guardrails.rb", "class Guardrails; def call(e); e[:b1]=true; end; end")
      write_hook(dir2, "guardrails.rb", "class Guardrails; def call(e); e[:b2]=true; end; end")
      registry = Samagotchi::Hooks::Registry.new
      meta = { "guardrails.rb" => { "event" => "before_tool_call", "on_error" => "skip", "priority" => 10 } }
      described_class.load(bundle_name: "bundle-one", hooks_dir: dir1, metadata: meta, registry: registry)
      described_class.load(bundle_name: "bundle-two", hooks_dir: dir2, metadata: meta, registry: registry)
      expect(registry.size).to eq(2)
      e = {}
      registry.fire(:before_tool_call, e)
      expect(e[:b1]).to be true
      expect(e[:b2]).to be true
      # Namespaces are distinct
      ns1 = described_class.namespace_for("bundle-one")
      ns2 = described_class.namespace_for("bundle-two")
      expect(ns1).not_to eq(ns2)
    end

    it "gives hyphen vs underscore bundle names distinct namespaces (injective)" do
      ns_hyphen = described_class.namespace_for("my-bundle")
      ns_under = described_class.namespace_for("my_bundle")
      expect(ns_hyphen).not_to eq(ns_under)
      # Also ensure both are valid constants
      expect(ns_hyphen.to_s).to start_with("Samagotchi::Bundles::")
      expect(ns_under.to_s).to start_with("Samagotchi::Bundles::")
    end

    it "fails fast when file does not define expected class (const_get false)" do
      hooks_dir = File.join(tmpdir, "hooks")
      # File is array.rb but defines no Array class inside bundle namespace; should raise and warn, not resolve ::Array
      write_hook(hooks_dir, "array.rb", "# empty file, no class")
      registry = Samagotchi::Hooks::Registry.new
      meta = { "array.rb" => { "event" => "before_tool_call", "on_error" => "skip" } }
      expect { described_class.load(bundle_name: "bad-bundle", hooks_dir: hooks_dir, metadata: meta, registry: registry) }.not_to raise_error
      expect(registry.size).to eq(0)
      # Ensure it warned
      expect { described_class.load(bundle_name: "bad-bundle2", hooks_dir: hooks_dir, metadata: meta, registry: registry) }.to output(/failed to load/).to_stderr
    end

    it "raises if plugin does not respond to #call" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "no_call.rb", "class NoCall; end")
      registry = Samagotchi::Hooks::Registry.new
      meta = { "no_call.rb" => { "event" => "before_tool_call", "on_error" => "skip" } }
      loaded = described_class.load(bundle_name: "nocall-bundle", hooks_dir: hooks_dir, metadata: meta, registry: registry)
      expect(loaded).to eq(0)
      expect(registry.size).to eq(0)
    end

    it "skips hook with no event" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "audit.rb", "class Audit; def call(e); end; end")
      registry = Samagotchi::Hooks::Registry.new
      meta = { "audit.rb" => { "event" => "", "on_error" => "skip" } }
      loaded = described_class.load(bundle_name: "test", hooks_dir: hooks_dir, metadata: meta, registry: registry)
      expect(loaded).to eq(0)
      expect(registry.size).to eq(0)
    end

    it "fail_closed denies the call on before_tool_call when the hook raises" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "guardrails.rb", "class Guardrails; def call(e); raise \"boom\"; end; end")
      registry = Samagotchi::Hooks::Registry.new
      sha = Digest::SHA256.hexdigest(File.read(File.join(hooks_dir, "guardrails.rb")))
      meta = { "guardrails.rb" => { "event" => "before_tool_call", "on_error" => "fail_closed", "sha256" => sha } }
      described_class.load(bundle_name: "fail-bundle", hooks_dir: hooks_dir, metadata: meta, registry: registry)
      verdict = Samagotchi::Guardrails::Verdict.new(call: { name: "bad" })
      registry.fire(:before_tool_call, { tool_name: "bad", guardrail: verdict })
      expect(verdict).to be_deny
      expect([verdict.reason, verdict.rule, verdict.decided_by]).to eq(
        ["guardrail guardrails.rb (bundle fail-bundle) raised RuntimeError: boom", "guardrail-load", "core"]
      )
    end

    it "fail_closed denies whatever the hook raises, not only a StandardError" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "deep.rb", "class Deep; def call(e); raise NotImplementedError, \"later\"; end; end")
      registry = Samagotchi::Hooks::Registry.new
      sha = Digest::SHA256.hexdigest(File.read(File.join(hooks_dir, "deep.rb")))
      meta = { "deep.rb" => { "event" => "before_tool_call", "on_error" => "fail_closed", "sha256" => sha } }
      described_class.load(bundle_name: "deep-bundle", hooks_dir: hooks_dir, metadata: meta, registry: registry)
      verdict = Samagotchi::Guardrails::Verdict.new(call: { name: "x" })
      registry.fire(:before_tool_call, { guardrail: verdict })
      expect(verdict).to be_deny
    end

    it "fail_closed: through the Gate, a raise denies the call and the next hook sees event[:blocked]" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "guardrails.rb", "class Guardrails; def call(e); raise \"boom\"; end; end")
      registry = Samagotchi::Hooks::Registry.new
      sha = Digest::SHA256.hexdigest(File.read(File.join(hooks_dir, "guardrails.rb")))
      meta = { "guardrails.rb" => { "event" => "before_tool_call", "on_error" => "fail_closed", "priority" => 10, "sha256" => sha } }
      described_class.load(bundle_name: "fail-bundle", hooks_dir: hooks_dir, metadata: meta, registry: registry)
      seen = nil
      registry.register(:before_tool_call) { |e| seen = e.slice(:blocked, :block_reason) }
      verdict = Samagotchi::Guardrails::Gate.new(-> { registry }).evaluate({ name: "execute" }, iteration: 1, params: "")
      reason = "guardrail guardrails.rb (bundle fail-bundle) raised RuntimeError: boom"
      expect([verdict.decision, verdict.reason]).to eq([:deny, reason])
      expect(seen).to eq(blocked: true, block_reason: reason)
    end

    it "logs an on_error: log :generation_progress hook's raise once a minute" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "stream_audit.rb", "class StreamAudit; def call(e); raise \"boom\"; end; end")
      registry = Samagotchi::Hooks::Registry.new
      meta = { "stream_audit.rb" => { "event" => "generation_progress", "on_error" => "log" } }
      described_class.load(bundle_name: "stream-bundle", hooks_dir: hooks_dir, metadata: meta, registry: registry)
      failed = []
      allow(Samagotchi::Log).to receive(:warn).with(:hooks, "bundle_hook_failed", any_args) { failed << :failed }
      3.times { registry.fire(:generation_progress, { type: :generation_progress }) }
      expect(failed.size).to eq(1)
    end

    it "log on_error warns to stderr and continues" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "audit.rb", "class Audit; def call(e); raise \"log me\"; end; end")
      registry = Samagotchi::Hooks::Registry.new
      meta = { "audit.rb" => { "event" => "after_tool_call", "on_error" => "log" } }
      described_class.load(bundle_name: "log-bundle", hooks_dir: hooks_dir, metadata: meta, registry: registry)
      e = {}
      expect { registry.fire(:after_tool_call, e) }.to output(/audit.*failed/).to_stderr
      expect(e[:blocked]).to be_nil
    end

    it "skip on_error is silent" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "silent.rb", "class Silent; def call(e); raise \"silent\"; end; end")
      registry = Samagotchi::Hooks::Registry.new
      meta = { "silent.rb" => { "event" => "after_tool_call", "on_error" => "skip" } }
      described_class.load(bundle_name: "silent-bundle", hooks_dir: hooks_dir, metadata: meta, registry: registry)
      e = {}
      expect { registry.fire(:after_tool_call, e) }.not_to output.to_stderr
    end

    it "bad file warns and continues to next hook" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "good.rb", "class Good; def call(e); e[:good]=true; end; end")
      write_hook(hooks_dir, "bad.rb", "raise \"syntax boom\"")
      registry = Samagotchi::Hooks::Registry.new
      meta = {
        "good.rb" => { "event" => "before_tool_call", "on_error" => "skip" },
        "bad.rb" => { "event" => "before_tool_call", "on_error" => "skip" }
      }
      expect { described_class.load(bundle_name: "cont-bundle", hooks_dir: hooks_dir, metadata: meta, registry: registry) }.to output(/bad\.rb.*failed to load/).to_stderr
      # good hook should still be registered
      expect(registry.size).to eq(1)
      e = {}
      registry.fire(:before_tool_call, e)
      expect(e[:good]).to be true
    end

    it "handles symbol-keyed metadata (provenance style)" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "guardrails.rb", "class Guardrails; def call(e); e[:sym]=true; end; end")
      registry = Samagotchi::Hooks::Registry.new
      # Simulate JSON.parse symbolize_names keys
      meta_sym = { :"guardrails.rb" => { event: "before_tool_call", on_error: "skip" } }
      loaded = described_class.load(bundle_name: "sym-bundle", hooks_dir: hooks_dir, metadata: meta_sym, registry: registry)
      expect(loaded).to eq(1)
      e = {}
      registry.fire(:before_tool_call, e)
      expect(e[:sym]).to be true
    end
  end

  describe ".namespace_for" do
    it "creates distinct modules per bundle" do
      ns1 = described_class.namespace_for("a")
      ns2 = described_class.namespace_for("b")
      expect(ns1).not_to eq(ns2)
    end
  end

  describe ".instantiate" do
    it "strips .rb extension for class name" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "my_hook.rb", "class MyHook; def call(e); end; end")
      described_class.namespace_for("test-inst")
      klass = described_class.instantiate("test-inst", "my_hook.rb", File.join(hooks_dir, "my_hook.rb"))
      expect(klass).to respond_to(:call)
    end
  end

  describe "fail-closed loading" do
    require "samagotchi/guardrails/load_failures"
    let(:failures) { Samagotchi::Guardrails::LoadFailures.new }
    let(:hooks_dir) { File.join(tmpdir, "hooks") }
    let(:registry) { Samagotchi::Hooks::Registry.new }
    let(:code) { "class Guard; def call(e); e[:hit] = true; end; end" }

    def load_with(meta)
      described_class.load(bundle_name: "g", hooks_dir: hooks_dir, metadata: { "guard.rb" => meta }, registry: registry,
                           failures: failures)
    end

    def sha = Digest::SHA256.hexdigest(code)

    before { write_hook(hooks_dir, "guard.rb", code) }

    it "doesn't load a hook whose file changed since install, and a required one fails" do
      File.write(File.join(hooks_dir, "guard.rb"), "#{code}\n# edited")
      expect { load_with("event" => "before_tool_call", "on_error" => "fail_closed", "sha256" => "sha256:#{sha}") }
        .to output(/hook 'guard.rb' not loaded: its sha256 .* differs/).to_stderr
      expect(registry.size).to eq(0)
      expect(failures.required.map(&:what)).to eq(["hook guard.rb (bundle g)"])
      edited = Digest::SHA256.hexdigest("#{code}\n# edited")
      expect(failures.required.first.reason)
        .to eq("its sha256 #{edited[0, 12]}… differs from the installed #{sha[0, 12]}… (edited after install? reinstall the bundle)")
    end

    it "reports a changed non-required hook without failing closed" do
      expect { load_with("event" => "after_turn", "sha256" => "0" * 64) }.to output(/not loaded/).to_stderr
      expect(failures.list.size).to eq(1)
      expect(failures.required).to be_empty
    end

    it "loads a required hook whose sha matches" do
      expect(load_with("event" => "before_tool_call", "on_error" => "fail_closed", "sha256" => "sha256:#{sha}")).to eq(1)
      expect(failures).not_to be_any
    end

    it "fails a required hook with no recorded sha, but loads a plain one" do
      load_with("event" => "before_tool_call", "on_error" => "fail_closed")
      expect(failures.required.first.reason).to include("no sha256 recorded")
      failures2 = Samagotchi::Guardrails::LoadFailures.new
      loaded = described_class.load(bundle_name: "g", hooks_dir: hooks_dir, registry: registry, failures: failures2,
                                    metadata: { "guard.rb" => { "event" => "after_turn" } })
      expect([loaded, failures2.any?]).to eq([1, false])
    end

    it "fails a required hook that is missing or doesn't load" do
      FileUtils.rm_f(File.join(hooks_dir, "guard.rb"))
      load_with("event" => "before_tool_call", "on_error" => "fail_closed", "sha256" => sha)
      expect(failures.required.first.reason).to eq("the file is missing")

      bad = "class Guard; def call(e)\n"
      write_hook(hooks_dir, "guard.rb", bad)
      failures2 = Samagotchi::Guardrails::LoadFailures.new
      expect do
        described_class.load(bundle_name: "g", hooks_dir: hooks_dir, registry: registry, failures: failures2,
                             metadata: { "guard.rb" => { "event" => "before_tool_call", "on_error" => "fail_closed",
                                                         "sha256" => Digest::SHA256.hexdigest(bad) } })
      end.to output(/failed to load: SyntaxError/).to_stderr
      expect(failures2.required.first.reason).to start_with("SyntaxError")
    end
  end
end
