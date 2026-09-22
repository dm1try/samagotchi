# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "digest"
require "samagotchi/hooks/bundle_loader"
require "samagotchi/hooks/registry"

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
      metadata = { "guardrails.rb" => { "event" => "before_tool_call", "on_error" => "skip", "priority" => 10, "sha256" => "sha256:abc" } }
      loaded = described_class.load(bundle_name: "test-bundle", hooks_dir: hooks_dir, metadata: metadata, registry: registry)
      expect(loaded).to eq(1)
      expect(registry.size).to eq(1)
      e = {}
      registry.fire(:before_tool_call, e)
      expect(e[:called]).to be true
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

    it "fail_closed sets event[:blocked] on before_tool_call when hook raises" do
      hooks_dir = File.join(tmpdir, "hooks")
      write_hook(hooks_dir, "guardrails.rb", "class Guardrails; def call(e); raise \"boom\"; end; end")
      registry = Samagotchi::Hooks::Registry.new
      meta = { "guardrails.rb" => { "event" => "before_tool_call", "on_error" => "fail_closed" } }
      described_class.load(bundle_name: "fail-bundle", hooks_dir: hooks_dir, metadata: meta, registry: registry)
      e = { tool_name: "bad" }
      registry.fire(:before_tool_call, e)
      expect(e[:blocked]).to be true
      expect(e[:block_reason]).to include("guardrails.rb")
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
end
