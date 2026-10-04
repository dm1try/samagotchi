# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"
require "stringio"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/memory_bundle/provenance"
require "samagotchi/memory_bundle/installer"
require "support/test_kernel"

RSpec.describe Samagotchi::Engine, "bundle hooks" do
  let(:tmpdir) { Dir.mktmpdir("engine-bundle-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }
  let(:client) do
    dbl = test_client
    allow(dbl).to receive(:complete).and_return(nil)
    dbl
  end

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  before do
    FileUtils.mkdir_p(system_dir)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def write_bundle(src_name, files = {}, hooks = {}, trust_level: nil, version: "1.0.0")
    src = File.join(tmpdir, "src_#{src_name}_#{rand(1000)}")
    FileUtils.mkdir_p(src)
    FileUtils.mkdir_p(File.join(src, "hooks"))
    files.each { |k, v| File.write(File.join(src, k), v) }
    hooks.each { |k, v| File.write(File.join(src, "hooks", k), v) }
    manifest = { "name" => src_name, "version" => version, "files" => {}, "hooks" => {} }
    files.each { |k, v| manifest["files"][k] = "sha256:#{Digest::SHA256.hexdigest(v)}" }
    hooks.each { |k, v| manifest["hooks"][k] = { "sha256" => "sha256:#{Digest::SHA256.hexdigest(v)}", "event" => "before_tool_call", "on_error" => "fail_closed", "priority" => 10 } }
    manifest["trust_level"] = trust_level if trust_level
    File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))
    src
  end

  it "registers bundle hooks into @hooks (in an isolated config home)" do
    src = write_bundle("test-hooks", { "identity.md" => "# Id\n" }, { "guardrails.rb" => "class Guardrails; def call(e); e[:hit]=true; end; end" }, trust_level: "reviewed")
    Samagotchi::MemoryBundle::Installer.new(source: src, name: "test-hooks", scope: "system", force: false, strict: true).run
    engine = described_class.new(client: client)
    hooks = engine.instance_variable_get(:@hooks)
    expect(hooks.size).to be >= 1
    e = {}
    hooks.fire(:before_tool_call, e)
    expect(e[:hit]).to be true
  end

  it "warns (not swallows) on a hook edited after install, and doesn't load it" do
    src = write_bundle("broken-hooks", { "identity.md" => "# Id\n" }, { "bad.rb" => "class Bad; def call(e); end; end" }, trust_level: "reviewed")
    Samagotchi::MemoryBundle::Installer.new(source: src, name: "broken-hooks", scope: "system", force: false, strict: true).run
    # Corrupt the installed hook to raise at load time (runtime error)
    bad_path = File.join(bundles_dir, "broken-hooks", "hooks", "bad.rb")
    File.write(bad_path, "raise \"boom during load\"")
    engine = nil
    expect do
      engine = described_class.new(client: client)
    end.to output(/broken-hooks.*not loaded: its sha256/).to_stderr
    expect(engine.guardrail_failures.list.map(&:what)).to eq(["hook bad.rb (bundle broken-hooks)"])
  end

  it "empty bundles dir is a no-op" do
    FileUtils.rm_rf(bundles_dir)
    expect { described_class.new(client: client) }.not_to raise_error
  end

  it "prints experimental warning for experimental bundle and stays quiet for reviewed" do
    src_exp = write_bundle("exp-bundle", { "identity.md" => "# Id\n" }, { "guardrails.rb" => "class Guardrails; def call(e); end; end" }) # no trust_level => experimental
    Samagotchi::MemoryBundle::Installer.new(source: src_exp, name: "exp-bundle", scope: "system", force: false, strict: true).run
    expect do
      described_class.new(client: client)
    end.to output(/exp-bundle.*experimental/).to_stderr

    # Clean and test reviewed is quiet
    FileUtils.rm_rf(File.join(bundles_dir, "exp-bundle"))
    src_rev = write_bundle("rev-bundle", { "identity.md" => "# Id\n" }, { "guardrails.rb" => "class Guardrails; def call(e); end; end" }, trust_level: "reviewed")
    Samagotchi::MemoryBundle::Installer.new(source: src_rev, name: "rev-bundle", scope: "system", force: false, strict: true).run
    expect do
      described_class.new(client: client)
    end.not_to output(/experimental/).to_stderr
  end

  it "guardrail fires on turn 2, not just turn 1 (survives ensure clear_hooks — Policy 4 regression)" do
    src = write_bundle("turn2-bundle", { "identity.md" => "# Id\n" }, { "guardrails.rb" => "class Guardrails; def call(e); raise \"x\" if e[:tool_name]==\"bad\"; end; end" }, trust_level: "reviewed")
    Samagotchi::MemoryBundle::Installer.new(source: src, name: "turn2-bundle", scope: "system", force: false, strict: true).run

    engine = described_class.new(client: client)
    # Stub the kernel that Engine created internally
    k = engine.instance_variable_get(:@kernel)
    allow(k).to receive(:run) do |_messages, **_kwargs|
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: [], exhausted: false, pending_tool_calls: false, tool_activity: [])
    end
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)

    # First turn
    engine.run_turn(session, "hi")
    hooks = engine.instance_variable_get(:@hooks)
    # After first turn, bundle hook should still be present (clear_all spares it)
    expect(hooks.size).to eq(1)
    v1 = Samagotchi::Guardrails::Verdict.new(call: { name: "bad" })
    hooks.fire(:before_tool_call, { tool_name: "bad", guardrail: v1 })
    expect(v1).to be_deny

    # Second turn — should still veto
    engine.run_turn(session, "hi2")
    v2 = Samagotchi::Guardrails::Verdict.new(call: { name: "bad" })
    hooks.fire(:before_tool_call, { tool_name: "bad", guardrail: v2 })
    expect(v2).to be_deny
  end

  it "proves trust_level persistence is wired end-to-end (installer → provenance → engine warning)" do
    src = write_bundle("trust-e2e", { "identity.md" => "# Id\n" }, { "guardrails.rb" => "class Guardrails; def call(e); end; end" }, trust_level: "experimental")
    Samagotchi::MemoryBundle::Installer.new(source: src, name: "trust-e2e", scope: "system", force: false, strict: true).run
    prov = Samagotchi::MemoryBundle::Provenance.new(name: "trust-e2e")
    expect(prov.read[:trust_level]).to eq("experimental")
    expect do
      described_class.new(client: client)
    end.to output(/trust-e2e.*experimental/).to_stderr
  end
end
