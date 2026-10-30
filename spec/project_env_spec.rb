# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/project_env"
require "samagotchi/tools/task_runtime"

RSpec.describe Samagotchi::ProjectEnv do
  let(:tmp) { Dir.mktmpdir("project-env") }
  let(:project) { File.join(tmp, "project").tap { |d| FileUtils.mkdir_p(d) } }
  let(:old_bin) { File.join(tmp, "old", "bin").tap { |d| make_executable(File.join(d, "ruby")) } }
  let(:new_bin) { File.join(tmp, "new", "bin").tap { |d| make_executable(File.join(d, "ruby")) } }
  let(:shim_dir) { File.join(tmp, "state", "samagotchi", "bin") }
  let(:mise) { File.join(tmp, "fake-mise") }
  let(:seen) { File.join(tmp, "seen.json") }
  let(:env) do
    { "PATH" => "#{old_bin}:/usr/bin:/bin", "GEM_HOME" => "/spawner/gems", "GEM_PATH" => "/spawner/gems",
      "__MISE_DIFF" => "stale", "__MISE_SESSION" => "stale", "MISE_SHELL" => "zsh", "HOME" => tmp,
      "SAMAGOTCHI_MISE_CLI" => mise, "XDG_CONFIG_HOME" => File.join(tmp, "config") }
  end

  before { allow(Samagotchi::Log).to receive(:warn) }

  after { FileUtils.remove_entry(tmp) }

  def make_executable(file, body = "#!/bin/sh\n")
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, body)
    File.chmod(0o755, file)
  end

  # A fake `mise`: records its argv and the __MISE_*/MISE_SHELL it was given,
  # then prints +json+ (or runs +script+ instead).
  def fake_mise(json = nil, script: nil)
    body = script || <<~SH
      #!/bin/sh
      /usr/bin/env | /usr/bin/grep -E '^(__MISE_|MISE_SHELL|MISE_YES|CI=)' > #{seen}.env
      /usr/bin/env | /usr/bin/grep -E '^MISE_TRUSTED_CONFIG_PATHS=' > #{seen}.trusted
      echo "$@" > #{seen}.argv
      cat <<'JSON'
      #{JSON.generate(json)}
      JSON
    SH
    make_executable(mise, body)
  end

  def overlay(**opts)
    @result = described_class.compute(project, env: env, mode: "mise", home: nil, cwd: project, shim_dir: shim_dir,
                                               **opts)
  end

  # The env a tool gets: the worker's, then the overlay (nil unsets).
  def tools = env.merge(@result.env).compact

  def project_path = "#{new_bin}:/usr/bin:/bin"

  it "applies `mise env -C DIR --json` without mise's shell state, and marks it" do
    fake_mise({ "PATH" => project_path, "RUBY_ROOT" => "/new", "__MISE_DIFF" => "x", "__MISE_SESSION" => "y",
                "__MISE_ORIG_PATH" => "z", "MISE_SHELL" => "zsh" })
    result = overlay

    expect(result.applied).to be(true)
    expect(tools["PATH"]).to eq(project_path)
    expect(tools["RUBY_ROOT"]).to eq("/new")
    expect(tools.keys.grep(/MISE_(DIFF|SESSION|ORIG_PATH|SHELL)/)).to be_empty
    expect(result.env).to be_frozen
    expect(File.read("#{seen}.argv").strip).to eq("env -C #{project} --json")
    expect(File.read("#{seen}.env")).to be_empty
    expect(tools["SAMAGOTCHI_PROJECT_ENV"]).to eq("mise:#{File.realpath(File.join(new_bin, "ruby"))}")
    expect(Samagotchi::Log).not_to have_received(:warn)
  end

  it "never answers mise's trust prompt for it, and keeps the user's trust list" do
    env.update("MISE_YES" => "1", "CI" => "true", "MISE_TRUSTED_CONFIG_PATHS" => "/mine")
    fake_mise({ "PATH" => project_path })
    overlay
    expect(File.read("#{seen}.env")).to be_empty
    expect(File.read("#{seen}.trusted").strip).to eq("MISE_TRUSTED_CONFIG_PATHS=/mine")
  end

  it "never takes chi's own config from the project: HOME, XDG_*, SAMAGOTCHI_*, RACK_ENV, CI dropped, warned once" do
    fake_mise({ "PATH" => project_path, "HOME" => "/evil", "XDG_CONFIG_HOME" => "/evil", "XDG_DATA_HOME" => "/evil",
                "SAMAGOTCHI_GUARDRAILS_ENABLED" => "false", "SAMAGOTCHI_MISE_CLI" => "/evil", "RACK_ENV" => "test",
                "CI" => "1", "CHI_REMOTE" => "evil", "DATABASE_URL" => "postgres://p" })
    overlay
    expect(tools.values_at("HOME", "XDG_CONFIG_HOME", "SAMAGOTCHI_MISE_CLI")).to eq([tmp, File.join(tmp, "config"), mise])
    expect(@result.env.keys).not_to include("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "SAMAGOTCHI_MISE_CLI")
    expect(tools).not_to include("XDG_DATA_HOME", "SAMAGOTCHI_GUARDRAILS_ENABLED", "RACK_ENV", "CI", "CHI_REMOTE")
    expect(tools["DATABASE_URL"]).to eq("postgres://p")
    expect(Samagotchi::Log).to have_received(:warn)
      .with(:worker, "project_env_reserved", dir: project,
                                             keys: "CHI_REMOTE,CI,HOME,RACK_ENV,SAMAGOTCHI_GUARDRAILS_ENABLED,SAMAGOTCHI_MISE_CLI,XDG_CONFIG_HOME,XDG_DATA_HOME").once
  end

  it "never takes TMPDIR from the project: the guardrails' $TMPDIR and tmp dirs are the worker's" do
    env["TMPDIR"] = "/worker/tmp/"
    fake_mise({ "PATH" => project_path, "TMPDIR" => "/project/checkout" })
    overlay
    expect(@result.env).not_to include("TMPDIR")
    expect(tools["TMPDIR"]).to eq("/worker/tmp/")
    expect(Samagotchi::Log).to have_received(:warn).with(:worker, "project_env_reserved", dir: project, keys: "TMPDIR")
  end

  it "never touches the worker's own env: its keys, proxies and remotes stay the spawner's" do
    before_env = env.dup
    fake_mise({ "PATH" => project_path, "ANTHROPIC_API_KEY" => "sk-project", "https_proxy" => "http://evil:8080" })
    overlay
    expect(env).to eq(before_env)
    expect(tools).to include("ANTHROPIC_API_KEY" => "sk-project", "https_proxy" => "http://evil:8080")
  end

  describe "the record of the worker's own values (for a chi a tool runs)" do
    it "holds each key the overlay changes, as the worker has it (nil: unset)" do
      fake_mise({ "PATH" => project_path, "DATABASE_URL" => "postgres://p" })
      overlay
      expect(described_class.restore_env(tools)).to eq(
        "PATH" => "#{old_bin}:/usr/bin:/bin", "DATABASE_URL" => nil, "GEM_HOME" => "/spawner/gems",
        "GEM_PATH" => "/spawner/gems", "__MISE_DIFF" => "stale", "__MISE_SESSION" => "stale", "MISE_SHELL" => "zsh"
      )
    end

    it "never brings back a reserved key, sets a loader or Bundler variable (only unsets it), nor reads a bad record" do
      forged = JSON.generate("XDG_CONFIG_HOME" => "/x", "SAMAGOTCHI_GUARDRAILS_ENABLED" => "false", "HOME" => nil,
                             "DYLD_INSERT_LIBRARIES" => "/x.dylib", "LD_PRELOAD" => "/x.so", "RUBYOPT" => "-r/x",
                             "RUBYLIB" => "/x", "RUBYGEMS_GEMDEPS" => "-", "BUNDLE_GEMFILE" => "/x", "A" => "1", "B" => 2,
                             "LD_LIBRARY_PATH" => nil, "BUNDLE_BIN_PATH" => nil)
      expect(described_class.restore_env("SAMAGOTCHI_PROJECT_ENV_ORIG" => forged))
        .to eq("A" => "1", "LD_LIBRARY_PATH" => nil, "BUNDLE_BIN_PATH" => nil)
      expect(described_class.restore_env("SAMAGOTCHI_PROJECT_ENV_ORIG" => "[")).to eq({})
    end
  end

  it "is taken back by a chi a tool runs (bin/chi, before config): the worker's values, the marker kept" do
    tool_env = { "PATH" => "/shim:/project/bin", "ANTHROPIC_API_KEY" => "sk-project", "LD_LIBRARY_PATH" => "/p/lib",
                 "SAMAGOTCHI_PROJECT_ENV" => "mise:/p/ruby",
                 "SAMAGOTCHI_PROJECT_ENV_ORIG" => JSON.generate("PATH" => "/usr/bin", "ANTHROPIC_API_KEY" => "sk-mine",
                                                                "LD_LIBRARY_PATH" => nil) }
    described_class.take_orig!(tool_env)
    expect(tool_env).to eq("PATH" => "/usr/bin", "ANTHROPIC_API_KEY" => "sk-mine", "SAMAGOTCHI_PROJECT_ENV" => "mise:/p/ruby")
    bin = File.read(File.expand_path("../bin/chi", __dir__))
    expect(bin.index("ProjectEnv.take_orig!")).to be < bin.index("ConfigFile.load!")
  end

  it "is none:no_dir for a session without a folder" do
    fake_mise({ "PATH" => project_path })
    expect(described_class.compute("", env: env, mode: "mise", home: nil, cwd: project, shim_dir: shim_dir).marker)
      .to eq("none:no_dir")
  end

  describe "the spawner's GEM_HOME/GEM_PATH" do
    it "are dropped when the project's ruby is another one" do
      fake_mise({ "PATH" => project_path })
      overlay
      expect(tools).not_to include("GEM_HOME", "GEM_PATH")
    end

    it "are kept when the ruby stays the same" do
      fake_mise({ "PATH" => "#{old_bin}:/usr/bin", "NODE_VERSION" => "22" })
      overlay
      expect(tools.values_at("GEM_HOME", "GEM_PATH")).to eq(["/spawner/gems", "/spawner/gems"])
    end

    it "give way to the ones mise sets" do
      fake_mise({ "PATH" => project_path, "GEM_HOME" => "/project/gems" })
      overlay
      expect(tools["GEM_HOME"]).to eq("/project/gems")
      expect(tools).not_to include("GEM_PATH")
    end

    it "are dropped when exactly one of the two rubies is a mise shim" do
      shim_bin = File.join(tmp, "shims")
      FileUtils.mkdir_p(shim_bin)
      make_executable(File.join(tmp, "real", "mise"))
      File.symlink(File.join(tmp, "real", "mise"), File.join(shim_bin, "ruby"))
      fake_mise({ "PATH" => "#{shim_bin}:/usr/bin" })
      overlay
      expect(tools).not_to include("GEM_HOME", "GEM_PATH")
    end

    it "are kept when neither PATH has a ruby" do
      env["PATH"] = File.join(tmp, "empty")
      fake_mise({ "PATH" => File.join(tmp, "empty2") })
      overlay
      expect(tools["GEM_HOME"]).to eq("/spawner/gems")
    end
  end

  describe "a project env not applied" do
    let(:before_env) { env.dup }

    def expect_untouched(reason)
      expect(env).to eq(before_env)
      expect(@result.env).to eq("SAMAGOTCHI_PROJECT_ENV" => "none:#{reason}")
    end

    it "warns once when mise fails (an untrusted mise.toml)" do
      before_env
      fake_mise(script: "#!/bin/sh\necho 'mise ERROR Config files in #{project}/mise.toml are not trusted.' >&2\n" \
                        "echo 'Trust them with `mise trust`.' >&2\necho 'mise ERROR Version: 2026.10.17' >&2\nexit 1\n")
      expect(overlay.reason).to eq("mise_failed")
      expect_untouched("mise_failed")
      error = "mise_failed: exit 1: Config files in #{project}/mise.toml are not trusted. / Trust them with `mise trust`."
      expect(Samagotchi::Log).to have_received(:warn)
        .with(:worker, "project_env", reason: "mise_failed", dir: project, error: error).once
    end

    it "warns when mise doesn't answer in time, and leaves no process behind" do
      before_env
      fake_mise(script: "#!/bin/sh\necho $$ > #{seen}.pid\nexec sleep 30\n")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(overlay(timeout: 0.3).reason).to eq("mise_timeout")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(5, below: 30)
      expect_untouched("mise_timeout")
      pid = File.read("#{seen}.pid").to_i
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
      expect(Samagotchi::Log).to have_received(:warn).with(:worker, "project_env", hash_including(reason: "mise_timeout")).once
    end

    it "warns on an answer that isn't a JSON object" do
      before_env
      fake_mise(script: "#!/bin/sh\necho 'export PATH=/x'\n")
      expect(overlay.reason).to eq("bad_json")
      expect_untouched("bad_json")
      expect(Samagotchi::Log).to have_received(:warn).with(:worker, "project_env", hash_including(reason: "bad_json")).once
    end

    it "is a quiet no-op without mise (SAMAGOTCHI_MISE_CLI names a missing file)" do
      before_env
      expect(overlay.reason).to eq("no_mise")
      expect_untouched("no_mise")
      expect(Samagotchi::Log).not_to have_received(:warn)
    end

    it "is a quiet no-op when session.project_env is off" do
      before_env
      fake_mise({ "PATH" => project_path })
      expect(overlay(mode: "off").reason).to eq("off")
      expect_untouched("off")
      expect(File.exist?("#{seen}.argv")).to be(false)
    end

    it "skips and warns when the worker doesn't run in the session's folder (it is gone)" do
      before_env
      fake_mise({ "PATH" => project_path })
      expect(overlay(cwd: tmp).reason).to eq("cwd_mismatch")
      expect_untouched("cwd_mismatch")
      expect(Samagotchi::Log).to have_received(:warn)
        .with(:worker, "project_env", reason: "cwd_mismatch", dir: project, cwd: tmp).once
    end
  end

  it "gives tools its env without what every tool sets itself, NONE outside a worker" do
    expect(described_class.current).to eq(described_class::NONE)
    expect(described_class::TOOLS_DROP).to eq(Samagotchi::Tools::TaskRuntime::SANITIZED_ENV_KEYS)
    fake_mise({ "PATH" => project_path, "RUBYLIB" => "/p", "BUNDLE_GEMFILE" => "/p/Gemfile", "A" => "1" })
    described_class.install!(overlay)
    expect(described_class.tools_env).to include("A" => "1", "PATH" => project_path)
    expect(described_class.tools_env.keys).not_to include("RUBYLIB", "BUNDLE_GEMFILE")
  ensure
    described_class.reset!
  end

  describe ".find_mise" do
    let(:path_mise) { File.join(tmp, "path-bin", "mise").tap { |f| make_executable(f) } }

    it "uses SAMAGOTCHI_MISE_CLI only, when set" do
      expect(described_class.find_mise(env: { "SAMAGOTCHI_MISE_CLI" => mise, "PATH" => File.dirname(path_mise) })).to be_nil
      make_executable(mise)
      expect(described_class.find_mise(env: { "SAMAGOTCHI_MISE_CLI" => mise })).to eq(mise)
    end

    it "prefers home.json's mise, then PATH" do
      home_mise = File.join(tmp, "home-bin", "mise").tap { |f| make_executable(f) }
      lookup_env = { "PATH" => File.dirname(path_mise), "XDG_CONFIG_HOME" => File.join(tmp, "config") }
      expect(described_class.find_mise(env: lookup_env)).to eq(path_mise)
      home = Samagotchi::ChiHome::Record.new(ruby: "/r", gem_home: "/g", gem_path: "/g", mise: home_mise, set_at: "t",
                                             set_by_version: "1")
      Samagotchi::ChiHome.write!(home, path: Samagotchi::ChiHome.path(env: lookup_env))
      expect(described_class.find_mise(env: lookup_env)).to eq(home_mise)
    end
  end

  describe "the chi shim" do
    let(:home_gems) { File.join(tmp, "home-gems") }
    let(:home) do
      Samagotchi::ChiHome::Record.new(ruby: File.join(tmp, "home", "bin", "ruby"), gem_home: home_gems,
                                      gem_path: home_gems, mise: nil, set_at: "t", set_by_version: "1")
    end

    it "goes first on the overlaid PATH, once, holding only chi" do
      fake_mise({ "PATH" => "#{shim_dir}:#{project_path}" })
      overlay(home: home)
      expect(tools["PATH"]).to eq("#{shim_dir}:#{project_path}")
      expect(Dir.children(shim_dir)).to eq(["chi"])
    end

    it "is there with no project env too, and no PATH change without a home" do
      overlay(home: home)
      expect(tools["PATH"]).to start_with("#{shim_dir}:")
      FileUtils.rm_rf(shim_dir)
      overlay(home: nil)
      expect(tools["PATH"]).to eq(env["PATH"])
      expect(File.exist?(shim_dir)).to be(false)
    end
  end
end
