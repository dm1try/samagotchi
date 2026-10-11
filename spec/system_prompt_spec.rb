# frozen_string_literal: true

require "tmpdir"
require "samagotchi/system_prompt"

RSpec.describe Samagotchi::SystemPrompt do
  subject(:prompt) do
    described_class.new(profile: -> {}, tools: -> { [] }, session: -> {}, thinking: -> {})
  end

  around do |example|
    saved = ENV["PATH"]
    Dir.mktmpdir do |bin|
      @bin = bin
      example.run
    ensure
      ENV["PATH"] = saved
    end
  end

  def rg_available? = prompt.send(:rg_available?)

  # A PATH with no `command` program on it, as on Linux (macOS ships
  # /usr/bin/command): the check must not depend on a shell builtin.
  it "finds rg on PATH without a shell" do
    File.write(File.join(@bin, "rg"), "#!/bin/sh\n")
    File.chmod(0o755, File.join(@bin, "rg"))
    ENV["PATH"] = @bin
    expect(rg_available?).to be(true)
  end

  it "doesn't find rg when no PATH folder has it" do
    ENV["PATH"] = @bin
    expect(rg_available?).to be(false)
  end

  describe "AGENTS.md" do
    def description(cwd)
      saved = ENV["SAMAGOTCHI_SKIP_AGENTS_MD"]
      ENV.delete("SAMAGOTCHI_SKIP_AGENTS_MD")
      Dir.chdir(cwd) { prompt.send(:project_specific_description) }
    ensure
      saved.nil? ? ENV.delete("SAMAGOTCHI_SKIP_AGENTS_MD") : ENV["SAMAGOTCHI_SKIP_AGENTS_MD"] = saved
    end

    def write(path, text)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end

    let(:repo) { File.join(File.realpath(@bin), "repo") }

    before { FileUtils.mkdir_p(File.join(repo, ".git")) }

    it "is read from the work tree root when chi runs in a subdirectory" do
      write(File.join(repo, "AGENTS.md"), "root notes")
      FileUtils.mkdir_p(File.join(repo, "lib", "deep"))
      expect(description(File.join(repo, "lib", "deep"))).to eq("Project specific description:\nroot notes")
    end

    it "is the chain from the work tree root down to the current directory, root first" do
      write(File.join(repo, "AGENTS.md"), "root notes")
      write(File.join(repo, "pkg", "AGENTS.md"), "pkg notes")
      write(File.join(repo, "pkg", "inner", "AGENTS.md"), "inner notes")
      expect(description(File.join(repo, "pkg", "inner"))).to eq(
        "Project specific description:\nroot notes\n\n" \
        "Project specific description for pkg/:\npkg notes\n\n" \
        "Project specific description for pkg/inner/:\ninner notes"
      )
    end

    it "gives the plain header to a subdirectory's AGENTS.md when the root has none" do
      write(File.join(repo, "sub", "AGENTS.md"), "sub notes")
      expect(description(File.join(repo, "sub"))).to eq("Project specific description:\nsub notes")
    end

    it "leaves out an empty file in the chain" do
      write(File.join(repo, "AGENTS.md"), "  \n")
      write(File.join(repo, "sub", "AGENTS.md"), "sub notes")
      expect(description(File.join(repo, "sub"))).to eq("Project specific description:\nsub notes")
    end

    it "loads none with skip_agents_md" do
      write(File.join(repo, "AGENTS.md"), "root notes")
      write(File.join(repo, "sub", "AGENTS.md"), "sub notes")
      ENV["SAMAGOTCHI_SKIP_AGENTS_MD"] = "true"
      expect(Dir.chdir(File.join(repo, "sub")) { prompt.send(:project_specific_description) }).to be_nil
    ensure
      ENV.delete("SAMAGOTCHI_SKIP_AGENTS_MD")
    end

    it "is read from a linked worktree's own checkout, not the main one" do
      write(File.join(repo, "AGENTS.md"), "main checkout notes")
      FileUtils.mkdir_p(File.join(repo, ".git", "worktrees", "wt"))
      wt = File.join(File.dirname(repo), "wt")
      write(File.join(wt, ".git"), "gitdir: #{File.join(repo, ".git", "worktrees", "wt")}\n")
      write(File.join(wt, "AGENTS.md"), "worktree notes")
      FileUtils.mkdir_p(File.join(wt, "src"))
      expect(description(File.join(wt, "src"))).to eq("Project specific description:\nworktree notes")
    end

    # AGENTS.md is the cross-tool name; the old AGENT.md has no fallback.
    it "doesn't read an AGENT.md" do
      write(File.join(repo, "AGENT.md"), "old notes")
      expect(description(repo)).to be_nil
      write(File.join(repo, "AGENTS.md"), "new notes")
      expect(description(repo)).to eq("Project specific description:\nnew notes")
    end

    it "is only the current directory's outside a git repository" do
      outside = File.join(File.realpath(@bin), "plain", "sub")
      FileUtils.mkdir_p(outside)
      write(File.join(File.realpath(@bin), "plain", "AGENTS.md"), "parent notes")
      expect(description(outside)).to be_nil
    end
  end
end

RSpec.describe Samagotchi::SystemPrompt, "#memory_index" do
  subject(:prompt) do
    described_class.new(profile: -> { Samagotchi::ModelProfile.for("gemma4") }, tools: -> { Samagotchi::Tools::Registry.new },
                        session: -> {}, thinking: -> {})
  end

  let(:index_text) { +"- **a** · 9 B\n" }

  before do
    allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return([])
    text = index_text
    allow(Samagotchi::Tools::MemoryRead).to receive(:call) { |name, **| name.to_s.empty? ? text.dup : "Error: none" }
  end

  def figures(text) = { tokens: (text.length / 4.0).ceil, lines: text.lines.size }

  it "follows the cache key of the prompt built last, back to an already-built one" do
    expect(prompt.memory_index).to be_nil
    first = index_text.dup
    prompt.build(chat: true, layers: [])
    index_text << "- **b** · 9 B\n"
    prompt.build(chat: true, layers: [:forget])
    expect(prompt.memory_index).to eq(system: figures(index_text), project: figures(index_text))
    prompt.build(chat: true, layers: [])
    expect(prompt.memory_index).to eq(system: figures(first), project: figures(first))
    prompt.reset!
    prompt.build(chat: true, layers: [])
    expect(prompt.memory_index).to eq(system: figures(index_text), project: figures(index_text))
  end
end

RSpec.describe Samagotchi::SystemPrompt, "#prompt_files" do
  subject(:prompt) do
    described_class.new(profile: -> { Samagotchi::ModelProfile.for("gemma4") }, tools: -> { Samagotchi::Tools::Registry.new },
                        session: -> {}, thinking: -> {})
  end

  around do |example|
    saved = ENV.delete("SAMAGOTCHI_SKIP_AGENTS_MD")
    Dir.mktmpdir do |tmp|
      @repo = File.join(File.realpath(tmp), "repo")
      FileUtils.mkdir_p(File.join(@repo, ".git"))
      FileUtils.mkdir_p(File.join(@repo, "pkg"))
      File.write(File.join(@repo, "AGENTS.md"), "root notes")
      File.write(File.join(@repo, "pkg", "AGENTS.md"), "pkg notes")
      example.run
    end
  ensure
    saved.nil? ? ENV.delete("SAMAGOTCHI_SKIP_AGENTS_MD") : ENV["SAMAGOTCHI_SKIP_AGENTS_MD"] = saved
  end

  before do
    allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return([])
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
  end

  def build_in(dir) = Dir.chdir(dir) { prompt.build(chat: true) }

  it "is the chain in the prompt built last, [] before a build and after #reset!" do
    expect(prompt.prompt_files).to eq([])
    text = build_in(File.join(@repo, "pkg"))
    expect(prompt.prompt_files).to eq([File.join(@repo, "AGENTS.md"), File.join(@repo, "pkg", "AGENTS.md")])
    expect(text).to include("Project specific description:\nroot notes\n\nProject specific description for pkg/:\npkg notes\n")
    prompt.reset!
    expect(prompt.prompt_files).to eq([])
  end

  it "leaves out an empty file" do
    File.write(File.join(@repo, "pkg", "AGENTS.md"), "\n")
    build_in(File.join(@repo, "pkg"))
    expect(prompt.prompt_files).to eq([File.join(@repo, "AGENTS.md")])
  end
end

RSpec.describe Samagotchi::SystemPrompt, "appended files" do
  around do |example|
    saved = ENV.delete("SAMAGOTCHI_SKIP_AGENTS_MD")
    Dir.mktmpdir do |tmp|
      @tmp = File.realpath(tmp)
      @repo = File.join(@tmp, "repo")
      FileUtils.mkdir_p(File.join(@repo, ".git"))
      FileUtils.mkdir_p(File.join(@repo, "pkg"))
      File.write(File.join(@repo, "AGENTS.md"), "root notes")
      example.run
    end
  ensure
    saved.nil? ? ENV.delete("SAMAGOTCHI_SKIP_AGENTS_MD") : ENV["SAMAGOTCHI_SKIP_AGENTS_MD"] = saved
  end

  let(:config_entries) { [] }

  before do
    allow(Samagotchi::ConfigFile).to receive_messages(preloaded_memories: [], appended_prompt_files: config_entries)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call) { |name, **| name.to_s.empty? ? "- **idx** · 1 B\n" : "Error: none" }
  end

  def prompt_for(files)
    described_class.new(profile: -> { Samagotchi::ModelProfile.for("gemma4") }, tools: -> { Samagotchi::Tools::Registry.new },
                        session: -> {}, thinking: -> {}, appended_files: files)
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def build_in(prompt, dir = @repo) = Dir.chdir(dir) { prompt.build(chat: true) }

  it "goes after the AGENTS.md chain and before the memory indexes, one section per file" do
    a = write(File.join(@repo, "docs", "a.md"), "alpha")
    b = write(File.join(@tmp, "elsewhere", "b.md"), "beta")
    prompt = prompt_for([a, b])
    text = build_in(prompt)
    expect(text).to include("Project specific description:\nroot notes\n" \
                            "Appended from docs/a.md:\nalpha\n\nAppended from #{b}:\nbeta\nProject memories:")
    expect(prompt.prompt_files).to eq([File.join(@repo, "AGENTS.md"), a, b])
  end

  it "puts the config entries first, resolves a relative one against the cwd and skips a missing one" do
    write(File.join(@repo, "pkg", "CLAUDE.md"), "claude notes")
    cli = write(File.join(@repo, "cli.md"), "cli notes")
    config_entries.replace(["CLAUDE.md", "missing.md", cli])
    prompt = prompt_for([cli])
    text = build_in(prompt, File.join(@repo, "pkg"))
    expect(text).to include("Appended from pkg/CLAUDE.md:\nclaude notes\n\nAppended from cli.md:\ncli notes\nProject memories:")
    expect(text.scan("cli notes").size).to eq(1)
    expect(prompt.prompt_files).to eq([File.join(@repo, "AGENTS.md"), File.join(@repo, "pkg", "CLAUDE.md"), cli])
  end

  it "drops a file the AGENTS.md chain already holds, and leaves out an empty one" do
    empty = write(File.join(@repo, "empty.md"), "\n")
    prompt = prompt_for([File.join(@repo, "AGENTS.md"), empty])
    text = build_in(prompt)
    expect(text.scan("root notes").size).to eq(1)
    expect(text).not_to include("Appended from")
    expect(prompt.prompt_files).to eq([File.join(@repo, "AGENTS.md")])
  end

  it "leaves out a file gone at a later rebuild" do
    a = write(File.join(@repo, "a.md"), "alpha")
    prompt = prompt_for([a])
    expect(build_in(prompt)).to include("Appended from a.md:\nalpha")
    File.delete(a)
    prompt.reset!
    expect(build_in(prompt)).not_to include("Appended from")
    expect(prompt.prompt_files).to eq([File.join(@repo, "AGENTS.md")])
  end

  it "reads the config list once, when the prompt is made" do
    prompt_for([])
    prompt = prompt_for([])
    build_in(prompt)
    prompt.reset!
    build_in(prompt)
    expect(Samagotchi::ConfigFile).to have_received(:appended_prompt_files).twice
  end
end
