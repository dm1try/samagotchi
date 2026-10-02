# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "samagotchi/utf8_default"
require "samagotchi/system_prompt"

# LC_ALL=C (or no locale at all) makes Ruby read files as US-ASCII; chi's
# memories, AGENT.md and sessions are UTF-8.
RSpec.describe Samagotchi::Utf8Default do
  around do |example|
    saved = Encoding.default_external
    verbose = $VERBOSE
    $VERBOSE = nil # Encoding.default_external= warns
    example.run
  ensure
    Encoding.default_external = saved
    $VERBOSE = verbose
  end

  def as_ascii
    Encoding.default_external = Encoding::US_ASCII
  end

  it "makes files read as UTF-8 under the C locale, the locale left to child processes" do
    as_ascii
    env = { "LC_ALL" => "C" }
    described_class.apply!(env)
    expect(Encoding.default_external).to eq(Encoding::UTF_8)
    expect(env).to eq("LC_ALL" => "C")
  end

  it "sets LANG for workers and tools when there is no locale at all" do
    as_ascii
    env = {}
    described_class.apply!(env)
    expect(Encoding.default_external).to eq(Encoding::UTF_8)
    expect(env).to eq("LANG" => "en_US.UTF-8")
  end

  it "leaves another locale's encoding alone" do
    Encoding.default_external = Encoding::ISO_8859_1
    described_class.apply!({ "LANG" => "de_DE.ISO8859-1" })
    expect(Encoding.default_external).to eq(Encoding::ISO_8859_1)
  end

  describe "the system prompt under US-ASCII (no apply!)" do
    let(:tmp) { Dir.mktmpdir("utf8-") }
    let(:prompt) { Samagotchi::SystemPrompt.new(profile: -> {}, tools: -> { [] }, session: -> {}, thinking: -> {}) }

    around { |example| with_config_home(File.join(tmp, "config")) { example.run } }
    after { FileUtils.rm_rf(tmp) }

    it "reads the memory index, memories and AGENT.md as UTF-8" do
      system_dir = Samagotchi::MemoryPaths.system_dir
      FileUtils.mkdir_p(system_dir)
      File.write(File.join(system_dir, "index.md"), "- **notes** · system · 2026-10-02 · 1 KB — café notes\n")
      File.write(File.join(system_dir, "notes.md"), "naïve — but UTF-8\n")
      repo = File.join(tmp, "repo")
      FileUtils.mkdir_p(File.join(repo, ".git"))
      File.write(File.join(repo, "AGENT.md"), "Ünïcode project — notes\n")
      as_ascii
      saved = ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
      text = Dir.chdir(repo) { prompt.send(:system_prompt_with_index, "Base — with a dash", chat: true, thinking: :off) }
      expect(text.encoding).to eq(Encoding::UTF_8)
      expect(text).to include("café notes", "Ünïcode project")
      expect(Samagotchi::Tools::MemoryRead.call("notes", scope: "system")).to include("naïve")
    ensure
      ENV["SAMAGOTCHI_SKIP_AGENT_MD"] = saved if saved
    end
  end
end
