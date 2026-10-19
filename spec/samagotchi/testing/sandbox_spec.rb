# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "samagotchi/testing"

RSpec.describe Samagotchi::Testing::Sandbox do
  it "points chi's folders, HOME, git and the peer CLIs at a temp root, clears SAMAGOTCHI_*, and puts ENV back" do
    before = ENV.to_h
    with_env("SAMAGOTCHI_DEFAULT_MODEL" => "mine") do
      outside = ENV.to_h
      described_class.with do |sandbox|
        root = sandbox.root
        expect(described_class.current).to be(sandbox)
        expect(ENV.values_at("HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "GIT_CONFIG_GLOBAL"))
          .to all(start_with(root))
        expect(ENV.values_at("GIT_CONFIG_NOSYSTEM", "SAMAGOTCHI_KEYCHAIN", "SAMAGOTCHI_ENV")).to eq(%w[1 off test])
        expect(ENV).not_to have_key("SAMAGOTCHI_DEFAULT_MODEL")
        expect(sandbox.state_dir).to eq(File.join(root, "state", "samagotchi"))
        expect(File.directory?(sandbox.work_dir)).to be true

        path = sandbox.config("bundles" => { "x" => { every: 3 } })
        expect(YAML.safe_load_file(path)).to eq("bundles" => { "x" => { "every" => 3 } })
        expect(Samagotchi::Config.get("default.model")).to be_nil
      end
      expect(ENV.to_h).to eq(outside)
    end
    expect(ENV.to_h).to eq(before)
    expect(described_class.current).to be_nil
  end

  it "puts ENV back and removes its root when entering fails halfway" do
    before = ENV.to_h
    roots = []
    allow(Dir).to(receive(:mktmpdir).and_wrap_original { |make, *args| make.call(*args).tap { |root| roots << root } })
    allow(File).to receive(:write).and_call_original
    allow(File).to receive(:write).with(end_with("gitconfig"), "").and_raise(Errno::ENOSPC)

    expect { described_class.with { raise "not reached" } }.to raise_error(Errno::ENOSPC)

    # The keys only: a failure must not print the environment's values.
    expect(ENV.keys.select { |key| ENV[key] != before[key] } | (before.keys - ENV.keys)).to eq([])
    expect(described_class.current).to be_nil
    expect(roots.size).to eq(1)
    expect(File).not_to exist(roots.first)
  end

  it "points the data and cache homes at the temp root too, and puts them back" do
    with_env("XDG_DATA_HOME" => "/outside/data", "XDG_CACHE_HOME" => "/outside/cache") do
      described_class.with do |sandbox|
        expect(ENV.fetch("XDG_DATA_HOME")).to eq(File.join(sandbox.root, "data"))
        expect(ENV.fetch("XDG_CACHE_HOME")).to eq(File.join(sandbox.root, "cache"))
        expect(File.directory?(ENV.fetch("XDG_DATA_HOME"))).to be true
        expect(File.directory?(ENV.fetch("XDG_CACHE_HOME"))).to be true
      end
      expect(ENV.values_at("XDG_DATA_HOME", "XDG_CACHE_HOME")).to eq(%w[/outside/data /outside/cache])
    end
  end

  it "writes memories as memory_write does, in the system scope or a checkout's project scope" do
    described_class.with do |sandbox|
      system = sandbox.write_memory("skill_a", "# A\n", description: "does a")
      expect(system).to eq(File.join(sandbox.memory_dir, "skill_a.md"))
      expect(File.read(system)).to eq("# A\n")
      expect(File.read(File.join(sandbox.memory_dir, "index.md"))).to match(/^- \*\*skill_a\*\* · system · .* — does a$/)

      project = sandbox.write_memory("notes", "n\n", scope: "project", cwd: sandbox.work_dir, source: "team")
      expect(project).to eq(File.join(sandbox.memory_dir("project", cwd: sandbox.work_dir), "notes.md"))
      expect(project).to start_with(sandbox.root)
      expect(File.read(File.join(File.dirname(project), "index.md"))).to include("from team")
      expect(Dir.pwd).not_to eq(sandbox.work_dir)
      expect { sandbox.write_memory("bad,name", "x") }.to raise_error(ArgumentError, /no commas/)
    end
  end

  it "puts fake commands first on PATH, a body replaced in place" do
    described_class.with do |sandbox|
      path = sandbox.fake_executable("gh", "echo one \"$@\"")
      expect(path).to eq(File.join(sandbox.bin_dir, "gh"))
      expect(`gh x`).to eq("one x\n")
      sandbox.fake_executable("gh", "echo two")
      expect(`gh`).to eq("two\n")
    end
  end

  it "nests: the inner one's leave brings the outer one back" do
    described_class.with do |outer|
      described_class.with { |inner| expect(ENV.fetch("HOME")).to start_with(inner.root) }
      expect(described_class.current).to be(outer)
      expect(ENV.fetch("HOME")).to start_with(outer.root)
    end
  end

  # The kit's load budget: no Engine, and well under chi's whole tree (a
  # clean process, so the suite's own requires don't count).
  it "requires no Engine with the kit, in under 250 chi files" do
    lib = File.expand_path("../../../lib", __dir__)
    script = 'require "samagotchi/testing"; print [$LOADED_FEATURES.grep(%r{/samagotchi/}).size, defined?(Samagotchi::Engine).inspect].join(" ")'
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
    expect(status).to be_success, err
    count, engine = out.split
    expect(engine).to eq("nil")
    expect(Integer(count)).to be < 250
  end
end

RSpec.describe Samagotchi::Testing::Waiting do
  include described_class

  it "waits for a truthy value, gives the last one at the deadline, or raises naming what it waited for" do
    calls = 0
    expect(wait_until { (calls += 1) >= 3 && :done }).to eq(:done)
    expect(wait_until(timeout: 0.05) { nil }).to be_nil
    expect { wait_until!("the moon", timeout: 0.05) { false } }.to raise_error("timed out after 0.05 s waiting for the moon")
    pid = Process.spawn("true")
    Process.wait(pid)
    expect(process_gone?(pid)).to be true
    expect(process_gone?(Process.pid)).to be false
  end
end
