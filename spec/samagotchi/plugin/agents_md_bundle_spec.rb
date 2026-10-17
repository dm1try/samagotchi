# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/memory_paths"
require "samagotchi/memory_bundle/installer"
require "support/thinking_off"
require "support/test_kernel"
require "samagotchi/testing/rspec"

# The agents-md bundle (lib/samagotchi/bundles/agents-md): a nested
# AGENTS.md steered in on the first tool touch under its directory. The
# plugin's hooks, driven through the bundle test kit against a fixture repo
# in a tmp dir (no git commits needed: only the .git layout matters), and
# the shipped bundle installed and loaded by an Engine.
RSpec.describe "The agents-md bundle", :bundle do
  include_context "thinking off"

  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/agents-md", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("agents-md-") }
  let(:repo) { File.realpath(File.join(tmpdir, "repo")) }
  let(:other) { File.realpath(File.join(tmpdir, "other")) }
  let(:link) { File.join(tmpdir, "link") }
  let(:chain) { [File.join(repo, "AGENTS.md"), File.join(repo, "pkg", "AGENTS.md")] }
  # The plugin as chi loads it, its session in pkg/ with the chain in its
  # prompt.
  let(:bundle) { plugin }
  let(:hooks) { bundle }

  before do
    FileUtils.mkdir_p(File.join(tmpdir, "repo", "pkg", "inner", "deep"))
    FileUtils.mkdir_p(File.join(tmpdir, "repo", "pkg2"))
    FileUtils.mkdir_p(File.join(tmpdir, "repo", "nested"))
    FileUtils.mkdir_p(File.join(tmpdir, "other"))
    system("git", "-C", repo, "init", "-q", exception: true)
    system("git", "-C", other, "init", "-q", exception: true)
    system("git", "-C", File.join(repo, "nested"), "init", "-q", exception: true)

    File.write(File.join(repo, "AGENTS.md"), "root rule")
    File.write(File.join(repo, "loose.txt"), "loose")
    File.write(File.join(repo, "pkg", "AGENTS.md"), "pkg rule")
    File.write(File.join(repo, "pkg", "file.txt"), "pkg file")
    File.write(File.join(repo, "pkg", "inner", "AGENTS.md"), "inner rule")
    File.write(File.join(repo, "pkg", "inner", "data.txt"), "data")
    File.write(File.join(repo, "pkg", "inner", "more.txt"), "more")
    File.write(File.join(repo, "pkg", "inner", "deep", "AGENTS.md"), "deep rule")
    File.write(File.join(repo, "pkg", "inner", "deep", "data.txt"), "deep data")
    File.write(File.join(repo, "pkg2", "AGENTS.md"), "pkg2 rule")
    File.write(File.join(repo, "pkg2", "file.txt"), "pkg2 file")
    File.write(File.join(repo, "nested", "AGENTS.md"), "nested rule")
    File.write(File.join(repo, "nested", "f.txt"), "nested file")
    File.write(File.join(other, "AGENTS.md"), "other rule")
    File.write(File.join(other, "f.txt"), "other file")
    File.symlink(repo, link) unless File.exist?(link)
  end

  after { FileUtils.rm_rf(tmpdir) }

  # The plugin as chi loads it (each call a new load, its own recorders),
  # for session s1 in pkg/, the cwd's AGENTS.md chain in its prompt.
  def plugin(settings = {})
    shipped_bundle("agents-md", settings: settings,
                                host: { cwd: File.join(repo, "pkg"), session_id: "s1", prompt_files: chain })
  end

  def fire(event, using: hooks)
    using.fire(event[:type], **event.except(:type))
  end

  def steers(using = hooks) = using.steers.map(&:text)

  def read(path, status: "ok", **event)
    fire({ type: :after_tool_call, tool: "read", status: status, call: { name: "read", content: path }, **event })
  end

  def write(path, status: "ok", **event)
    fire({ type: :after_tool_call, tool: "write", status: status, call: { name: "write", path: path }, **event })
  end

  def edit(path, status: "ok", **event)
    fire({ type: :after_tool_call, tool: "edit", status: status, call: { name: "edit", path: path }, **event })
  end

  def turn(messages: [])
    fire({ type: :before_turn, session_id: "s1", prompt: "go", messages: messages })
  end

  def steer_message(text) = { role: "user", kind: "steer", source: "agents-md", content: text }

  describe "steering" do
    it "steers a nested file's AGENTS.md into the turn" do
      read("inner/data.txt")

      expect(steers).to eq(["AGENTS.md for pkg/inner/ (applies to work under pkg/inner/):\ninner rule"])
    end

    it "steers the outermost candidates first" do
      read("inner/deep/data.txt")

      expect(steers.map { |text| text.lines.first.chomp }).to eq(
        ["AGENTS.md for pkg/inner/ (applies to work under pkg/inner/):",
         "AGENTS.md for pkg/inner/deep/ (applies to work under pkg/inner/deep/):"]
      )
    end

    it "leaves a file whose AGENTS.md is in the cwd's chain alone" do
      read("file.txt") # pkg/, in the chain

      expect(steers).to be_empty
    end

    it "leaves a file whose AGENTS.md was appended alone" do
      bundle.set(prompt_files: [File.join(repo, "AGENTS.md"), File.join(repo, "pkg2", "AGENTS.md")], cwd: repo)

      read("pkg2/file.txt")

      expect(steers).to be_empty
    end

    it "steers nothing for a file at the checkout top (its AGENTS.md is the chain's first)" do
      bundle.set(cwd: repo)

      read("loose.txt")

      expect(steers).to be_empty
    end

    it "steers each directory once: a second read under the same dir adds nothing" do
      read("inner/data.txt")
      read("inner/more.txt")

      expect(steers.size).to eq(1)
    end

    it "steers a write and an edit as for a read" do
      write("inner/data.txt")
      expect(steers.map { |text| text.lines.first.chomp }).to eq(["AGENTS.md for pkg/inner/ (applies to work under pkg/inner/):"])

      edit("inner/more.txt")
      expect(steers.size).to eq(1)
    end

    it "does nothing for a call that errored" do
      read("inner/data.txt", status: "error")

      expect(steers).to be_empty
    end

    it "does nothing for a tool outside its settings" do
      hooks = plugin("tools" => ["write"])

      fire({ type: :after_tool_call, tool: "read", status: "ok", call: { name: "read", content: "inner/data.txt" } }, using: hooks)
      expect(steers(hooks)).to be_empty
      fire({ type: :after_tool_call, tool: "write", status: "ok", call: { name: "write", path: "inner/data.txt" } }, using: hooks)
      expect(steers(hooks).size).to eq(1)
    end

    it "ignores a file in another repository" do
      bundle.set(cwd: repo)
      read("../other/f.txt")

      expect(steers).to be_empty
    end

    it "ignores a file in a nested repository of the checkout" do
      read("nested/f.txt")

      expect(steers).to be_empty
    end

    it "still matches through a symlinked cwd (a /tmp-style /private/tmp split)" do
      bundle.set(cwd: File.join(link, "pkg"))

      read("inner/data.txt")

      expect(steers).to eq(["AGENTS.md for pkg/inner/ (applies to work under pkg/inner/):\ninner rule"])
    end

    it "ignores a touched file outside any repository" do
      FileUtils.mkdir_p(File.join(tmpdir, "plain"))
      File.write(File.join(tmpdir, "plain", "AGENTS.md"), "plain rule")
      File.write(File.join(tmpdir, "plain", "f.txt"), "plain file")
      bundle.set(cwd: File.join(tmpdir, "plain")) # outside any checkout: no repo_root

      read("f.txt")

      expect(steers).to be_empty
    end
  end

  describe "the loaded set" do
    it "rebuilds from the steers already in the conversation: a resume re-steers nothing" do
      read("inner/data.txt")
      turn(messages: [steer_message(steers.first)])
      read("inner/more.txt")

      expect(steers.size).to eq(1)
    end

    it "a steer that was queued but dropped fires again on the next touch" do
      bundle.set(running: false) # the steer isn't queued: the turn ended first
      read("inner/data.txt")
      expect(steers).to be_empty
      bundle.set(running: true)

      turn(messages: []) # the rebuild finds none in the conversation

      read("inner/data.txt")

      expect(steers.size).to eq(1)
    end

    it "replaces, not accumulates: a dir whose steer is gone from the messages fires again" do
      read("inner/data.txt")
      turn(messages: [steer_message("unrelated")]) # inner's steer is not in there

      read("inner/more.txt")

      expect(steers.size).to eq(2)
    end

    it "skips other bundles' steers and messages" do
      turn(messages: [{ role: "user", kind: "steer", source: "loop-guard", content: "AGENTS.md for pkg/inner/ (applies to work under pkg/inner/):\nx" },
                      { role: "user", kind: "input", source: "user", content: "AGENTS.md for pkg/inner/ (applies to work under pkg/inner/):\nx" }])

      read("inner/data.txt")

      expect(steers.size).to eq(1)
    end
  end

  describe "the steer text" do
    it "cuts at max_chars with a pointer at the end, by an absolute path (the session runs in pkg/)" do
      File.write(File.join(repo, "pkg", "inner", "AGENTS.md"), "x" * 30)
      hooks = plugin("max_chars" => 20)
      fire({ type: :after_tool_call, tool: "read", status: "ok", call: { name: "read", content: "inner/data.txt" } }, using: hooks)

      expect(steers(hooks)).to eq(["AGENTS.md for pkg/inner/ (applies to work under pkg/inner/):\n#{"x" * 20}\n" \
                                "[cut at 20 of 30 chars: read #{File.realpath(repo)}/pkg/inner/AGENTS.md for the rest]"])
    end

    it "does not cut at exactly max_chars" do
      File.write(File.join(repo, "pkg", "inner", "AGENTS.md"), "x" * 20)
      hooks = plugin("max_chars" => 20)
      fire({ type: :after_tool_call, tool: "read", status: "ok", call: { name: "read", content: "inner/data.txt" } }, using: hooks)

      expect(steers(hooks)).to eq(["AGENTS.md for pkg/inner/ (applies to work under pkg/inner/):\n#{"x" * 20}"])
    end

    it "leaves an empty AGENTS.md out" do
      File.write(File.join(repo, "pkg", "inner", "AGENTS.md"), "  \n")
      read("inner/data.txt")

      expect(steers).to be_empty
    end
  end

  describe "skip_agents_md" do
    it "does nothing when the setting is on" do
      sandbox.config("skip_agents_md" => true)

      read("inner/data.txt")

      expect(steers).to be_empty
    end
  end

  # Installed as a user would, loaded by an Engine: the steer lands in the
  # real conversation, and a second turn re-steers nothing.
  # Off the kit's sandbox: an Engine under the suite's own environment.
  describe "the shipped bundle", bundle: false do
    let(:client) { test_client }
    let(:engine) { Samagotchi::Engine.new(client: client) }
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
    end

    around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

    around do |example|
      saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME")
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
      ENV["XDG_STATE_HOME"] = File.join(tmpdir, "state")
      # Before the outer before's fixture, so the chdir has a home.
      FileUtils.mkdir_p(File.join(tmpdir, "repo", "pkg"))
      Dir.chdir(File.join(repo, "pkg")) { example.run }
    ensure
      %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
    end

    before do
      # requires_chi names the release with ctx.prompt_files.
      stub_const("Samagotchi::VERSION", "0.60.0")
      FileUtils.mkdir_p(Samagotchi::MemoryPaths.system_dir)
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      @installer = Samagotchi::MemoryBundle::Installer.new(source: shipped, name: "agents-md", scope: "system", strict: true)
      @installer.run
    end

    def steers
      session.messages.select { |m| (m[:kind] || m["kind"]).to_s == "steer" && (m[:source] || m["source"]).to_s == "agents-md" }
    end

    it "installs cleanly and loads" do
      expect(@installer.warnings).to be_empty
      expect(engine.guardrail_failures.any?).to be(false)
    end

    it "steers the nested AGENTS.md on the first touch, and a second turn re-steers nothing" do
      replies = [%(<|tool_call>call:read{path: "inner/data.txt"}<tool_call|>), "done",
                 %(<|tool_call>call:read{path: "inner/more.txt"}<tool_call|>), "done"]
      allow(client).to receive(:complete) { replies.shift || "done" }

      engine.run_turn(session, "go")

      expect(steers.map { |m| m[:content] }).to eq(["AGENTS.md for pkg/inner/ (applies to work under pkg/inner/):\ninner rule"])

      engine.run_turn(session, "again")

      expect(steers.size).to eq(1)
      expect(session.messages.last[:content]).to eq("done")
    end
  end
end
