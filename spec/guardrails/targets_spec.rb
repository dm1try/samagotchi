# frozen_string_literal: true

require "tmpdir"
require "samagotchi/guardrails"
require "samagotchi/tools/builtins"

# outside_repo: measured from the session's repo root (the context cwd's),
# symlinks resolved on both sides, tmp dirs allowed unless the session
# lives in that tmp dir itself (Guardrails::Outside).
RSpec.describe "Guardrails::Targets#outside_repo?" do
  around do |example|
    Dir.mktmpdir("outside-repo") do |dir|
      @base = File.realpath(dir)
      @repo = File.join(@base, "repo").tap { |d| FileUtils.mkdir_p(d) }
      @sibling = File.join(@base, "sibling").tap { |d| FileUtils.mkdir_p(d) }
      system("git", "-C", @repo, "init", "-q", out: File::NULL, err: File::NULL)
      example.run
    end
  end

  let(:context) { Samagotchi::Guardrails::Context.new(cwd: @repo) }

  # targets(name: "write", path: "x") or targets({ ... }, ctx, registry: r)
  def targets(call = nil, ctx = context, registry: nil, **fields)
    Samagotchi::Guardrails::Targets.for(call || fields, ctx, registry: registry)
  end

  it "is the session's repo root" do
    sub = File.join(@repo, "lib").tap { |d| FileUtils.mkdir_p(d) }
    t = targets({ name: "write", path: "../spec/a_spec.rb" }, Samagotchi::Guardrails::Context.new(cwd: sub))
    expect(t.session_root).to eq(@repo)
    expect(t).not_to be_outside_repo
  end

  it "counts a path through a symlink into the repo as inside" do
    File.symlink(@repo, File.join(@sibling, "link"))
    expect(targets(name: "write", path: File.join(@sibling, "link", "a.txt"))).not_to be_outside_repo
  end

  it "counts a path through a symlink in the repo that points outside as outside" do
    File.symlink(@sibling, File.join(@repo, "out"))
    expect(targets(name: "write", path: "out/a.txt")).to be_outside_repo
  end

  it "compares /tmp and /private/tmp spellings of the same folder as the same" do
    real_tmp = File.realpath("/tmp")
    skip "/tmp is not a symlink here" if real_tmp == "/tmp"

    Dir.mktmpdir("outside-sbx", "/tmp") do |dir|
      name = File.basename(dir)
      ctx = Samagotchi::Guardrails::Context.new(cwd: File.join("/tmp", name))
      expect(targets({ name: "write", path: File.join(real_tmp, name, "a.txt") }, ctx)).not_to be_outside_repo
      expect(targets({ name: "write", path: File.join("/tmp", name, "a.txt") }, ctx)).not_to be_outside_repo
    end
  end

  describe "tmp dirs" do
    it "lets a write into a tmp dir through when the session lives elsewhere" do
      other_tmp = File.join(@base, "tmp").tap { |d| FileUtils.mkdir_p(d) }
      allow(Samagotchi::Guardrails::Outside).to receive(:tmp_roots).and_return([other_tmp])
      expect(targets(name: "write", path: File.join(other_tmp, "scratch.txt"))).not_to be_outside_repo
      expect(targets(name: "write", path: File.join(@sibling, "x.txt"))).to be_outside_repo
    end

    it "asks for a sibling in the tmp dir the session itself lives in" do
      allow(Samagotchi::Guardrails::Outside).to receive(:tmp_roots).and_return([@base])
      expect(targets(name: "write", path: File.join(@sibling, "x.txt"))).to be_outside_repo
    end

    it "lists Dir.tmpdir, /tmp and /var/tmp, resolved" do
      roots = Samagotchi::Guardrails::Outside.tmp_roots
      expect(roots).to include(File.realpath(Dir.tmpdir), File.realpath("/tmp"))
      expect(roots).to eq(roots.uniq)
    end
  end

  it "keeps a memory's .md file inside, not index.md" do
    project = Samagotchi::Tools::MemoryRead.memories_dir("project")
    expect(targets(name: "write", path: File.join(project, "notes.md"))).not_to be_outside_repo
    expect(targets(name: "write", path: File.join(project, "index.md"))).to be_outside_repo
  end

  it "measures a plugin call with its own outside cwd: from the session's repo" do
    registry = Samagotchi::Tools::Builtins.registry.tap do |r|
      r.register("save_note", schema: {}, handler: ->(*) { "" }, source: "notes",
                              targets: ->(call) { { paths: [call[:args]["path"]], cwd: call[:args]["cwd"] } })
    end
    t = targets({ name: "save_note", args: { "path" => "n.md", "cwd" => @sibling } }, registry: registry)
    expect([t.cwd, t.repo_root, t.session_root]).to eq([@sibling, nil, @repo])
    expect(t).to be_outside_repo
  end

  it "gives the session root in the hook event's targets" do
    expect(targets(name: "write", path: "a.txt").to_h).to include(outside_repo: false, repo_root: @repo)
  end
end
