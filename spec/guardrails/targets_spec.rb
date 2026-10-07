# frozen_string_literal: true

require "tmpdir"
require "samagotchi/guardrails"
require "samagotchi/tools/builtins"

# outside_repo? and git_outside_repo?: measured from the session's repo root (the context cwd's),
# symlinks resolved on both sides, tmp dirs allowed unless the session
# lives in that tmp dir itself (Guardrails::Outside).
RSpec.describe "Guardrails::Targets outside the session's repo" do
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

  it "says a memory_write writes a model overlay with current_model_only, never with remove" do
    overlay = Samagotchi::Guardrails::Targets.for({ name: "memory_write", path: "identity", scope: "system", content: "x",
                                                    current_model_only: true }, context, model_key: "qwen3-6")
    expect(overlay).to be_memory_overlay
    expect(overlay.paths.first).to end_with("/identity.qwen3-6.md")
    expect(targets(name: "memory_write", path: "h", scope: "project", content: "x")).not_to be_memory_overlay
    expect(targets(name: "memory_write", path: "h", scope: "project", remove: true, current_model_only: true)).not_to be_memory_overlay
    expect(targets(name: "write", path: "h.md", current_model_only: true)).not_to be_memory_overlay
  end

  describe ".prompt_memory_path?" do
    let(:sys) { Samagotchi::MemoryPaths.system_dir }
    let(:projects) { Samagotchi::MemoryPaths.projects_dir }

    it "is identity or a model note, with their overlays, right in the system or a project's memories folder" do
      [File.join(sys, "identity.md"), File.join(sys, "identity.qwen3-6.md"), File.join(sys, "model_notes_x.md"),
       File.join(projects, "repo_abc", "model_notes_x.key.md"), File.join(sys, "IDENTITY.md"),
       File.join(sys, "Model_Notes_x.md")].each do |path|
        expect(Samagotchi::Guardrails::Targets.prompt_memory_path?(path)).to be(true), path
      end
      [File.join(sys, "notes.md"), File.join(sys, "identity_extra.md"), File.join(sys, ".bundles", "g", "identity.md"),
       File.join(projects, "identity.md"), File.join(@repo, "model_notes_x.md"), File.join(sys, "model_notes_.txt")].each do |path|
        expect(Samagotchi::Guardrails::Targets.prompt_memory_path?(path)).to be(false), path
      end
    end

    it "follows a symlink and .. to the real folder" do
      FileUtils.mkdir_p(sys)
      File.symlink(sys, File.join(@repo, "mem"))
      expect(Samagotchi::Guardrails::Targets.prompt_memory_path?(File.join(@repo, "mem", "model_notes_x.md"))).to be(true)
      expect(Samagotchi::Guardrails::Targets.prompt_memory_path?(File.join(projects, "..", "identity.md"))).to be(true)
      expect(targets(name: "write", path: "mem/identity.md")).to be_prompt_memory
      expect(targets(name: "write", path: "mem/other.md")).not_to be_prompt_memory
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

  describe "git_dirs and git_outside_repo?" do
    it "reads a shell call's mutating git dirs, from its cwd:" do
      t = targets(name: "execute", content: "git add . && git -C #{@sibling} commit -m x")
      expect(t.git_dirs).to eq([@repo, @sibling])
      expect(t).to be_git_outside_repo
      expect(t.to_h).to include(git_dirs: [@repo, @sibling])
      t = targets(name: "task_create", content: "git commit -m x", cwd: @sibling)
      expect([t.git_dirs, t.git_outside_repo?]).to eq([[@sibling], true])
    end

    it "is not outside for git in the repo, an unknown dir, or a tmp dir the session doesn't live in" do
      expect(targets(name: "execute", content: "cd lib && git add .")).not_to be_git_outside_repo
      t = targets(name: "execute", content: "cd $REPO && git add .")
      expect([t.git_dirs, t.git_outside_repo?]).to eq([[:unknown], false])
      other_tmp = File.join(@base, "tmp").tap { |d| FileUtils.mkdir_p(d) }
      allow(Samagotchi::Guardrails::Outside).to receive(:tmp_roots).and_return([other_tmp])
      expect(targets(name: "execute", content: "cd #{other_tmp} && git init && git commit")).not_to be_git_outside_repo
    end

    it "is empty for a tool that isn't a shell tool" do
      t = targets(name: "write", path: File.join(@sibling, "x"))
      expect([t.git_dirs, t.git_outside_repo?, t.to_h[:git_dirs]]).to eq([[], false, []])
    end
  end
end
