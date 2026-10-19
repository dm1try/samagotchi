# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require "fileutils"
require "support/fake_provider_server"

# --set BUNDLE.KEY=VALUE on a session-starting run: checked against the
# installed bundles' records (session_settings:) and saved in the new
# session's file.
RSpec.describe "chi --set" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }

  it "is listed in --help" do
    out, = Open3.capture3(RbConfig.ruby, chi, "--help", stdin_data: "")
    expect(out).to include("--set BUNDLE.KEY=VALUE")
  end

  # A bundle record as an install leaves it (no plugin: only the record is read).
  def install_record(config, name, session_settings, types = {})
    dir = File.join(config, "samagotchi", "memories", ".bundles", name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "manifest.json"), JSON.generate("name" => name, "version" => "1.0.0",
                                                              "session_settings" => session_settings,
                                                              "session_setting_types" => types))
  end

  # chi with *args (and one --non-interactive turn against a fake llama.cpp
  # when +turn+): [stderr, exit status, the saved session file or nil].
  def run_chi(*args, turn: true)
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "ok", stop: true)}\n\n"])
    Dir.mktmpdir do |dir|
      config = File.join(dir, "config")
      install_record(config, "cost-cap", ["cap"], { "cap" => "number" })
      install_record(config, "plain", [])
      env = { "XDG_CONFIG_HOME" => config, "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
              "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_MODEL_PROFILE" => nil,
              "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1", "SAMAGOTCHI_SERVER_PORT" => server.port.to_s }
      extra = turn ? ["--non-interactive", "-p", "hi"] : []
      _out, err, status = Open3.capture3(env, RbConfig.ruby, chi, *args, *extra, stdin_data: "", chdir: dir)
      file = Dir.glob(File.join(dir, "state", "**", "*.json")).find { |path| File.basename(path, ".json").match?(/\A\h{8}-/) }
      [err, status.exitstatus, file && JSON.parse(File.read(file))]
    end
  ensure
    server&.stop
  end

  it "saves the bundle settings in the new session, a later --set of a key winning" do
    err, status, saved = run_chi("--set", "cost-cap.cap=3", "--set=cost-cap.cap=0.25")
    expect(status).to eq(0), err
    expect(saved["bundle_settings"]).to eq("cost-cap" => { "cap" => 0.25 })
  end

  it "reads .5 and 1e1 as numbers" do
    err, status, saved = run_chi("--set", "cost-cap.cap=.5")
    expect(status).to eq(0), err
    expect(saved["bundle_settings"]).to eq("cost-cap" => { "cap" => 0.5 })
    err, status, saved = run_chi("--set", "cost-cap.cap=1e1")
    expect(status).to eq(0), err
    expect(saved["bundle_settings"]).to eq("cost-cap" => { "cap" => 10.0 })
  end

  it "saves none without the flag" do
    err, status, saved = run_chi
    expect(status).to eq(0), err
    expect(saved["bundle_settings"]).to eq({})
  end

  it "refuses a bad shape, a bundle that isn't installed or a key it doesn't list (exit 2), and starts nothing" do
    {
      "foo" => "--set takes BUNDLE.KEY=VALUE, not foo",
      "a.b.c=1" => "one key under the bundle",
      "nope.x=1" => "--set nope.x: no installed bundle nope (bundles that take --set: cost-cap)",
      "cost-cap.default=1" => "--set cost-cap.default: cost-cap takes cap",
      "plain.x=1" => "--set plain.x: plain takes no session settings",
      "cost-cap.cap=five" => "--set cost-cap.cap: cost-cap takes a number (or off) for cap, not \"five\""
    }.each do |arg, message|
      err, status, saved = run_chi("--set", arg)
      expect(status).to eq(2), "#{arg}: #{err}"
      expect(err).to include(message), arg
      expect(saved).to be_nil, arg
    end
  end

  it "refuses it with chi web" do
    err, status, = run_chi("web", "--set", "cost-cap.cap=1", turn: false)
    expect(status).to eq(2)
    expect(err).to include("--set is a new session's")
  end
end
