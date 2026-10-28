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
                        hooks_dir: File.join(config_dir, "hooks"),
                        context_dir: File.join(root, "state", "context"))
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

  it "denies writes to attached context: a source's command runs later, outside the gate" do
    v = verdict_for(name: "write", path: "state/context/sessions/abc/pr-1.json", content: "{}")
    expect([v.decision, v.rule, v.source]).to eq([:deny, "chi-context", "core"])
  end

  # realpath gives an existing part its disk case; a missing tail keeps the
  # typed one, which a folding disk (macOS) creates in the same folder.
  it "takes a differently cased missing folder as the protected one on a disk that folds case, only there" do
    FileUtils.mkdir_p(File.join(root, "state"))
    folds = File.exist?(File.join(root, "STATE"))
    expect(described_class.folds_case?(File.join(root, "state", "context"))).to eq(folds)
    v = verdict_for(name: "write", path: "state/CONTEXT/src.yml", content: "{}")
    expect(v.decision).to eq(folds ? :deny : :allow)
    expect(described_class.under?(File.join(root, "state", "CONTEXT", "x"), File.join(root, "state", "context"))).to eq(folds)
    expect(described_class.under?(File.join(root, "state", "contextx"), File.join(root, "state", "context"))).to be(false)
    expect(described_class.under?("/nowhere-chi/A/b", "/nowhere-chi/a")).to be(false)
  end

  it "follows symlinks: a link into .bundles is denied too" do
    FileUtils.mkdir_p(File.join(config_dir, "memories", ".bundles", "b"))
    File.symlink(File.join(config_dir, "memories", ".bundles", "b"), File.join(root, "sneaky"))
    expect(verdict_for(name: "write", path: "sneaky/new.yml", content: "x")).to be_deny
  end

  it "takes a `..` after a symlinked dir from its target: mem/../config.yml is chi's config.yml" do
    FileUtils.mkdir_p(File.join(config_dir, "memories"))
    File.symlink(File.join(config_dir, "memories"), File.join(root, "mem"))
    v = verdict_for(name: "write", path: "mem/../config.yml", content: "x")
    expect([v.decision, v.rule]).to eq([:ask, "chi-config"])
    expect(verdict_for(name: "write", path: "mem/../.bundles/b/x", content: "x")).to be_allow
    expect(verdict_for(name: "write", path: "mem/.bundles/b/x", content: "x")).to be_deny
  end

  it "follows a dangling symlink to the protected file a write would create, and keeps the link's own place" do
    FileUtils.mkdir_p(File.join(config_dir, "hooks"))
    FileUtils.mkdir_p(File.join(config_dir, "memories", ".bundles", "b"))
    File.symlink(File.join(config_dir, "hooks", "new.rb"), File.join(root, "to-hook"))
    File.symlink(File.join(config_dir, "memories", ".bundles", "b", "hook.rb"), File.join(root, "to-bundle"))
    File.symlink(File.join(root, "to-bundle"), File.join(root, "to-to-bundle"))
    File.symlink(File.join(root, "elsewhere.rb"), File.join(config_dir, "memories", ".bundles", "b", "out.rb"))
    expect(verdict_for(name: "write", path: "to-hook", content: "x").rule).to eq("chi-hooks")
    expect(verdict_for(name: "write", path: "to-bundle", content: "x")).to be_deny
    expect(verdict_for(name: "write", path: "to-to-bundle", content: "x")).to be_deny
    expect(verdict_for(name: "write", path: "config/memories/.bundles/b/out.rb", content: "x")).to be_deny
  end

  describe ".expand, .real and .reals" do
    let(:deep) { File.join(root, "elsewhere", "deep").tap { |d| FileUtils.mkdir_p(d) } }

    before { File.symlink(deep, File.join(root, "link")) }

    it "is File.expand_path for a path with no `..` after a symlinked dir" do
      ["#{root}/a/../b", "#{root}/link/x/./y", "#{root}//a/b/", "#{root}/missing/../b", "/", "#{root}/.."].each do |path|
        expect(described_class.expand(path)).to eq(File.expand_path(path)), path
      end
      expect(described_class.expand("a/../b", root)).to eq(File.join(root, "b"))
      expect(described_class.expand("~/x/../y")).to eq(File.expand_path("~/y"))
    end

    it "climbs a `..` out of a symlinked dir's target, the kernel's way" do
      expect(described_class.expand("#{root}/link/../x")).to eq(File.join(root, "elsewhere", "x"))
      expect(described_class.expand("link/../../x", root)).to eq(File.join(root, "x"))
      expect(described_class.real("#{root}/link/../x")).to eq(File.join(root, "elsewhere", "x"))
      expect(described_class.reals("#{root}/link/../x")).to eq([File.join(root, "x"), File.join(root, "elsewhere", "x")])
      expect(described_class.reals("#{root}/link/x")).to eq([File.join(deep, "x")])
    end

    it "follows dangling symlinks, relative ones and chains, and stops on a loop" do
      File.symlink("elsewhere/new/../made.txt", File.join(root, "rel"))
      File.symlink(File.join(root, "rel"), File.join(root, "chain"))
      expect(described_class.real("#{root}/rel")).to eq(File.join(root, "elsewhere", "made.txt"))
      expect(described_class.real("#{root}/chain")).to eq(File.join(root, "elsewhere", "made.txt"))
      expect(described_class.reals("#{root}/chain")).to eq([File.join(root, "chain"), File.join(root, "elsewhere", "made.txt")])
      File.symlink(File.join(root, "loop-b"), File.join(root, "loop-a"))
      File.symlink(File.join(root, "loop-a"), File.join(root, "loop-b"))
      expect(described_class.real("#{root}/loop-a/x")).to be_a(String)
    end
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
  let(:engine) { Samagotchi::Engine.new(client: instance_double(Samagotchi::Client)) }
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
    expect(result.output).not_to include("denied")
    expect(File.read(config_path)).to end_with("# edited\n")
  end

  it "doesn't write when denied" do
    result, = write_config("Deny")
    expect(result.output).to include("The user declined this call. It needed approval (rule chi-config, core)")
    expect(File.read(config_path)).to eq(original)
  end
end
