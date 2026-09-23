# frozen_string_literal: true

require "tmpdir"
require "samagotchi/guardrails"
require "samagotchi/engine"

RSpec.describe Samagotchi::Guardrails::ProtectedPaths do
  let(:root) { File.realpath(Dir.mktmpdir("guard-prot")) }
  let(:config_dir) { File.join(root, "config").tap { |d| FileUtils.mkdir_p(d) } }
  let(:checks) do
    described_class.new(store_dir: File.join(root, "state", "guardrails"),
                        bundles_dir: File.join(config_dir, "memories", ".bundles"),
                        config_path: File.join(config_dir, "config.yml"),
                        hooks_dir: File.join(config_dir, "hooks"))
  end
  let(:context) { Samagotchi::Guardrails::Context.new(cwd: root) }

  after { FileUtils.rm_rf(root) }

  def verdict_for(call)
    v = Samagotchi::Guardrails::Verdict.new(call: call)
    v.context = context
    v.targets = Samagotchi::Guardrails::Targets.for(call, context)
    checks.check(v)
  end

  it "denies writes to the approval store and to installed bundles" do
    v = verdict_for(name: "write", path: "state/guardrails/approvals.json", content: "[]")
    expect([v.decision, v.rule, v.source]).to eq([:deny, "guardrail-store", "core"])
    v = verdict_for(name: "edit", path: "config/memories/.bundles/b/hooks/g.rb", content: "x")
    expect([v.decision, v.rule]).to eq([:deny, "installed-bundles"])
  end

  it "follows symlinks: a link into .bundles is denied too" do
    FileUtils.mkdir_p(File.join(config_dir, "memories", ".bundles", "b"))
    File.symlink(File.join(config_dir, "memories", ".bundles", "b"), File.join(root, "sneaky"))
    expect(verdict_for(name: "write", path: "sneaky/new.yml", content: "x")).to be_deny
  end

  it "asks (once or session only) for config.yml and the hooks dir" do
    v = verdict_for(name: "edit", path: "config/config.yml", content: "x")
    expect([v.decision, v.rule, v.scopes]).to eq([:ask, "chi-config", %w[once session]])
    expect(verdict_for(name: "write", path: "config/hooks/new.rb", content: "x").rule).to eq("chi-hooks")
  end

  it "denies a memory_write that lands in .bundles" do
    allow(Samagotchi::Tools::MemoryRead).to receive(:memories_dir).and_return(File.join(config_dir, "memories"))
    v = verdict_for(name: "memory_write", path: ".bundles/b/manifest", scope: "system", content: "x")
    expect(v).to be_deny
  end

  it "leaves reads, shell commands and other paths alone" do
    expect(verdict_for(name: "read", content: "config/config.yml")).to be_allow
    expect(verdict_for(name: "execute", content: "cat config/config.yml")).to be_allow
    expect(verdict_for(name: "write", path: "src/a.rb", content: "x")).to be_allow
    expect(verdict_for(name: "write", path: "config/config.yml.bak", content: "x")).to be_allow
  end
end

# The system bundle's config protocol edits config.yml with write/edit:
# after the user approves, the write goes through.
RSpec.describe "Engine: editing config.yml after an approval" do
  let(:engine) { Samagotchi::Engine.new(mode: :assist, client: instance_double(Samagotchi::Client)) }
  let(:config_path) { Samagotchi::ConfigFile.global_path }
  let(:kernel) { engine.instance_variable_get(:@kernel) }
  let(:original) { File.read(config_path) }

  before { original }
  after { File.write(config_path, original) }

  def write_config(answer)
    engine.interface = :repl
    asked = []
    engine.set_question_sync_handler do |pending|
      asked << pending
      engine.answer_question(id: pending[:id], selected: [answer]) if answer
      nil
    end
    call = { name: "write", path: config_path, content: "#{original}# edited\n" }
    result = Samagotchi::ToolRunner.new(kernel).run(call, iteration: 1, call_index: 1, call_count: 1,
                                                      on_stream_event: nil, max_tool_output_chars: nil)
    [result, asked]
  end

  it "asks, and writes once allowed" do
    result, asked = write_config("Allow once")
    expect(asked.first[:approval]).to include(rule: "chi-config", scopes: %w[once session])
    expect(result[:output]).not_to include("denied")
    expect(File.read(config_path)).to end_with("# edited\n")
  end

  it "doesn't write when denied" do
    result, = write_config("Deny")
    expect(result[:output]).to include("denied by guardrail (rule chi-config, core)")
    expect(File.read(config_path)).to eq(original)
  end
end
