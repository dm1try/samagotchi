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

# The agents-md bundle (lib/samagotchi/bundles/agents-md) installed and loaded by
# an Engine, against a fixture repo (its plugin alone:
# lib/samagotchi/bundles/agents-md/spec/).
RSpec.describe "The agents-md bundle" do
  include_context "thinking off"

  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/agents-md", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("agents-md-") }
  let(:repo) { File.realpath(File.join(tmpdir, "repo")) }
  let(:other) { File.realpath(File.join(tmpdir, "other")) }
  let(:link) { File.join(tmpdir, "link") }

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

  # Installed as a user would, loaded by an Engine: the steer lands in the
  # real conversation, and a second turn re-steers nothing.
  describe "the shipped bundle" do
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
