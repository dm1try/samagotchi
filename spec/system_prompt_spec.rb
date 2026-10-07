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

  describe "AGENT.md" do
    def description(cwd)
      saved = ENV["SAMAGOTCHI_SKIP_AGENT_MD"]
      ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
      Dir.chdir(cwd) { prompt.send(:project_specific_description) }
    ensure
      saved.nil? ? ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD") : ENV["SAMAGOTCHI_SKIP_AGENT_MD"] = saved
    end

    def write(path, text)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end

    let(:repo) { File.join(File.realpath(@bin), "repo") }

    before { FileUtils.mkdir_p(File.join(repo, ".git")) }

    it "is read from the work tree root when chi runs in a subdirectory" do
      write(File.join(repo, "AGENT.md"), "root notes")
      FileUtils.mkdir_p(File.join(repo, "lib", "deep"))
      expect(description(File.join(repo, "lib", "deep"))).to eq("Project specific description:\nroot notes")
    end

    it "prefers the current directory's AGENT.md over the root's" do
      write(File.join(repo, "AGENT.md"), "root notes")
      write(File.join(repo, "sub", "AGENT.md"), "sub notes")
      expect(description(File.join(repo, "sub"))).to eq("Project specific description:\nsub notes")
    end

    it "is read from a linked worktree's own checkout, not the main one" do
      write(File.join(repo, "AGENT.md"), "main checkout notes")
      FileUtils.mkdir_p(File.join(repo, ".git", "worktrees", "wt"))
      wt = File.join(File.dirname(repo), "wt")
      write(File.join(wt, ".git"), "gitdir: #{File.join(repo, ".git", "worktrees", "wt")}\n")
      write(File.join(wt, "AGENT.md"), "worktree notes")
      FileUtils.mkdir_p(File.join(wt, "src"))
      expect(description(File.join(wt, "src"))).to eq("Project specific description:\nworktree notes")
    end

    it "is only the current directory's outside a git repository" do
      outside = File.join(File.realpath(@bin), "plain", "sub")
      FileUtils.mkdir_p(outside)
      write(File.join(File.realpath(@bin), "plain", "AGENT.md"), "parent notes")
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
