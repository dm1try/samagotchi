# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"
require "digest"
require "samagotchi/engine"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/provenance"
require "samagotchi/memory_bundle/builder"
require "samagotchi/memory_bundle/uninstaller"

# A bundle's guardrails/*.yml: installed next to its hooks with the
# copied file's sha256, loaded by the Engine after the config's rules.
RSpec.describe "Bundle guardrail rule files" do
  let(:tmpdir) { Dir.mktmpdir("bundle-rules-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }
  let(:push_rules) do
    { "rules" => [{ "id" => "git-push", "tool" => "shell", "command" => "git push", "verdict" => "ask", "reason" => "publishes" }] }
  end

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  before do
    FileUtils.mkdir_p(system_dir)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def write_bundle(name, rules, version: "1.0.0", requires_chi: nil)
    src = File.join(tmpdir, "src_#{name}_#{rand(100_000)}")
    FileUtils.mkdir_p(File.join(src, "guardrails"))
    File.write(File.join(src, "guide.md"), "# Guide\n")
    rules.each { |file, doc| File.write(File.join(src, "guardrails", file), YAML.dump(doc)) }
    manifest = { "name" => name, "version" => version, "files" => { "guide.md" => "sha256:#{Digest::SHA256.hexdigest("# Guide\n")}" } }
    manifest["requires_chi"] = requires_chi if requires_chi
    File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))
    src
  end

  def install(src, name, **opts)
    Samagotchi::MemoryBundle::Installer.new(source: src, name: name, scope: "system", force: true, strict: true, **opts).run
  end

  def rules_dir(name) = File.join(bundles_dir, name, "guardrails")
  def manifest(name) = JSON.parse(File.read(File.join(bundles_dir, name, "manifest.json")))

  def engine = Samagotchi::Engine.new(client: instance_double(Samagotchi::Client))

  def evaluate(eng, content)
    eng.instance_variable_get(:@kernel).guardrail_gate.evaluate({ name: "execute", content: content }, iteration: 1, params: "")
  end

  describe "install" do
    it "copies guardrails/*.yml and records each copied file's sha256" do
      install(write_bundle("g", { "rules.yml" => push_rules }), "g")
      path = File.join(rules_dir("g"), "rules.yml")
      expect(File.exist?(path)).to be(true)
      expect(manifest("g")["guardrails"]).to eq("rules.yml" => { "sha256" => "sha256:#{Digest::SHA256.hexdigest(File.read(path))}" })
    end

    it "replaces an earlier version's set on upgrade" do
      install(write_bundle("g", { "old.yml" => push_rules }), "g")
      install(write_bundle("g", { "new.yml" => push_rules }, version: "1.1.0"), "g")
      expect(Dir.children(rules_dir("g"))).to eq(["new.yml"])
      expect(manifest("g")["guardrails"].keys).to eq(["new.yml"])
    end

    it "copies nothing on a dry run" do
      install(write_bundle("g", { "rules.yml" => push_rules }), "g", dry_run: true)
      expect(Dir.exist?(rules_dir("g"))).to be(false)
    end

    it "is removed with the bundle" do
      install(write_bundle("g", { "rules.yml" => push_rules }), "g")
      Samagotchi::MemoryBundle::Uninstaller.new(name: "g", force: true).run
      expect(Dir.exist?(File.join(bundles_dir, "g"))).to be(false)
    end

    it "is carried by chi bundle build" do
      install(write_bundle("g", { "rules.yml" => push_rules }), "g")
      out = File.join(tmpdir, "out")
      Samagotchi::MemoryBundle::Builder.new(scope: "system", name: "g", version: "1.0.0", out: out).run
      expect(YAML.load_file(File.join(out, "guardrails", "rules.yml"))).to eq(push_rules)
    end
  end

  describe "the Engine" do
    it "votes with an installed bundle's rules, source bundle <name>" do
      install(write_bundle("g", { "rules.yml" => push_rules }), "g")
      v = evaluate(engine, "git push origin main")
      expect([v.decision, v.rule, v.source]).to eq([:ask, "git-push", "bundle g"])
      expect(evaluate(engine, "ls")).to be_allow
    end

    it "orders bundles by name after the config's rules" do
      deny = { "rules" => [{ "id" => "b-rule", "tool" => "shell", "verdict" => "ask" }] }
      install(write_bundle("b", { "r.yml" => deny }), "b")
      install(write_bundle("a", { "r.yml" => { "rules" => [{ "id" => "a-rule", "tool" => "shell", "verdict" => "ask" }] } }), "a")
      expect(evaluate(engine, "ls").rule).to eq("a-rule")
    end

    it "denies every call when a rule file changed since install" do
      install(write_bundle("g", { "rules.yml" => push_rules }), "g")
      File.write(File.join(rules_dir("g"), "rules.yml"), YAML.dump("rules" => []))
      eng = nil
      expect { eng = engine }.to output(/rules rules.yml \(bundle g\): its sha256 differs/).to_stderr
      v = evaluate(eng, "ls")
      expect([v.decision, v.rule]).to eq([:deny, "guardrail-load"])
    end

    it "denies every call when a rule file doesn't parse, or its manifest is unreadable" do
      install(write_bundle("g", { "rules.yml" => { "rules" => [{ "id" => "x", "verdict" => "maybe", "tool" => "shell" }] } }), "g")
      eng = nil
      expect { eng = engine }.to output(/verdict must be ask or deny/).to_stderr
      expect(evaluate(eng, "ls")).to be_deny

      File.write(File.join(bundles_dir, "g", "manifest.json"), "{nope")
      expect { eng = engine }.to output(/manifest.json is unreadable/).to_stderr
      expect(evaluate(eng, "ls")).to be_deny
    end
  end

  # A running worker reads a bundle's rules again when they change; after
  # `chi update` the installed bundle may need a newer chi than the worker
  # runs (a rule key it doesn't know).
  describe "a bundle that needs a newer chi than this one" do
    let(:future_rules) do
      { "rules" => [{ "id" => "future", "tool" => "shell", "future_key" => "x", "verdict" => "deny" }] }
    end

    def warnings(events) = events.select { |e| e[:type] == :guardrail_warning }

    it "keeps the rules it loaded before and says so once per bundle version, no deny-all" do
      install(write_bundle("g", { "rules.yml" => push_rules }), "g")
      eng = engine
      events = []
      eng.subscribe(observer: ->(e) { events << e })
      expect(evaluate(eng, "git push").rule).to eq("git-push")

      install(write_bundle("g", { "rules.yml" => future_rules }, version: "2.0.0", requires_chi: ">= 99.0"), "g")
      v = evaluate(eng, "git push origin main")
      expect([v.decision, v.rule, v.source]).to eq([:ask, "git-push", "bundle g"])
      expect(evaluate(eng, "ls")).to be_allow
      expect(eng.guardrail_failures.list).to be_empty

      # Another reload (config.yml changed) keeps them and says nothing new.
      File.write(Samagotchi::ConfigFile.global_path, "guardrails:\n  rules: []\n")
      expect(evaluate(eng, "git push").rule).to eq("git-push")
      expect(warnings(events).size).to eq(1)
      expect(warnings(events).first[:message]).to eq(
        "bundle g 2.0.0 needs chi >= 99.0 and this session runs chi #{Samagotchi::VERSION}: its new rules are not " \
        "loaded, the ones loaded before still apply. Restart the session to load them " \
        "(chi sessions stop ID, then chi --resume ID)"
      )

      # Another too-new version: one more notice.
      install(write_bundle("g", { "rules.yml" => future_rules }, version: "2.1.0", requires_chi: ">= 99.0"), "g")
      expect(evaluate(eng, "git push").rule).to eq("git-push")
      expect(warnings(events).map { |e| e[:message][/bundle g \S+/] }).to eq(["bundle g 2.0.0", "bundle g 2.1.0"])
    end

    it "shows the notice as a turn event during a turn" do
      eng = engine
      sink = []
      allow(eng.instance_variable_get(:@turn_state)).to receive(:in_turn_sink).and_return([true, ->(e) { sink << e }])
      eng.send(:guardrail_notify, "kept")
      expect(sink).to eq([{ type: :guardrail_warning, message: "kept" }])
    end

    it "loads none of them and denies every call when it never loaded that bundle's rules" do
      install(write_bundle("g", { "rules.yml" => future_rules }, version: "2.0.0", requires_chi: ">= 99.0"), "g")
      eng = nil
      expect { eng = engine }.to output(/bundle g: its rules are not loaded: it requires chi >= 99.0/).to_stderr
      v = evaluate(eng, "ls")
      expect([v.decision, v.rule]).to eq([:deny, "guardrail-load"])
      expect(v.reason).to include("rules (bundle g) failed to load: it requires chi >= 99.0 (this is chi #{Samagotchi::VERSION})")
      expect(eng.guardrail_failures.message).to include("chi update")
    end
  end
end
