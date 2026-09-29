# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "stringio"
require "samagotchi/bootstrap_command"
require_relative "support/fake_provider_server"

# `chi bootstrap` end to end: bin/chi against a fake model server, with a
# temp XDG_CONFIG_HOME.
RSpec.describe "chi bootstrap" do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:chi) { File.expand_path("../bin/chi", __dir__) }
  let(:home) { Dir.mktmpdir("chi-bootstrap") }
  let(:config) { File.join(home, "config", "samagotchi", "config.yml") }
  let(:env) do
    { "HOME" => home, "XDG_CONFIG_HOME" => File.join(home, "config"), "XDG_STATE_HOME" => File.join(home, "state"),
      "SAMAGOTCHI_DEFAULT_MODEL" => nil, "SAMAGOTCHI_HOSTS_JSON" => nil, "FAKE_KEY" => nil }
  end
  let(:server) { FakeProviderServer.start }
  let(:target) { "127.0.0.1:#{server.port}" }
  let(:chat_ok) { { choices: [{ message: { role: "assistant", content: "ok" } }] } }

  after do
    server.stop
    FileUtils.rm_rf(home)
  end

  def bootstrap(*args, extra_env: {})
    Open3.capture3(env.merge(extra_env), RbConfig.ruby, chi, "bootstrap", *args, stdin_data: "")
  end

  def models(*ids) = { object: "list", data: ids.map { |id| { id: id } } }
  def written = YAML.safe_load(File.read(config))

  it "writes a native llama.cpp host with its model, n_ctx and profile" do
    server.default("/props", json: { model_alias: "qwen-a", build_info: "b1", chat_template: "<|im_start|> <function=",
                                     default_generation_settings: { n_ctx: 32_768 } })
    server.default("/v1/models", json: models("qwen-a"))
    server.default("/v1/chat/completions", json: chat_ok)

    out, err, status = bootstrap(target)

    expect([err, status.exitstatus]).to eq(["", 0])
    expect(out).to include("found: llama.cpp at http://#{target} (build b1)", "model: qwen-a", "context: 32768 tokens",
                           "profile: qwen36 (chat template: <|im_start|> + <function=)", "test: answered in",
                           "config: #{config} (new)", "next:  chi ")
    expect(written).to eq("default" => { "model" => "local:qwen-a" },
                          "hosts" => { "local" => { "host" => "127.0.0.1", "port" => server.port } })
    expect(server.requests.map(&:path)).to include("/props", "/v1/chat/completions")
  end

  it "writes an OpenAI-compatible host as api: openai" do
    server.default("/v1/models", json: models("splash"))
    server.default("/v1/chat/completions", json: chat_ok)

    out, _err, status = bootstrap(target, "--name", "splash")

    expect(status.exitstatus).to eq(0)
    expect(out).to include("found: an OpenAI-compatible API at http://#{target}/v1")
    expect(written["hosts"]).to eq("splash" => { "host" => "127.0.0.1", "port" => server.port, "api" => "openai" })
    expect(written.dig("default", "model")).to eq("splash:splash")
  end

  it "asks for --key-env on a 401 without a terminal, and uses the key's variable when given" do
    server.enqueue("/v1/models", status: 401, json: { error: { message: "no key" } })

    _out, err, status = bootstrap(target)

    expect(status.exitstatus).to eq(2)
    expect(err).to include("wants an API key (HTTP 401)", "--key-env VAR")

    server.default("/v1/models", json: models("m"))
    server.default("/v1/chat/completions", json: chat_ok)
    _out, _err, status = bootstrap(target, "--key-env", "FAKE_KEY", extra_env: { "FAKE_KEY" => "sk-1" })

    expect(status.exitstatus).to eq(0)
    expect(written.dig("hosts", "local")).to include("api_key_env" => "FAKE_KEY")
    expect(File.read(config)).not_to include("sk-1")
    expect(server.requests.last.header("Authorization")).to eq("Bearer sk-1")
  end

  it "refuses --key-env naming an unset variable" do
    _out, err, status = bootstrap(target, "--key-env", "FAKE_KEY")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("FAKE_KEY is not set")
  end

  it "lists several models and exits 2 without a terminal; --model picks one, case-insensitively" do
    server.default("/v1/models", json: models("alpha", "Beta"))
    server.default("/v1/chat/completions", json: chat_ok)

    _out, err, status = bootstrap(target)
    expect(status.exitstatus).to eq(2)
    expect(err).to include("has 2 models:", "  alpha", "  Beta", "--model ID")
    expect(File.exist?(config)).to be(false)

    _out, err, status = bootstrap(target, "--model", "gamma")
    expect(status.exitstatus).to eq(1)
    expect(err).to include("has no model gamma")

    _out, _err, status = bootstrap(target, "--model", "beta")
    expect(status.exitstatus).to eq(0)
    expect(written.dig("default", "model")).to eq("local:Beta")
  end

  it "writes nothing on --dry-run, and sends no test with --no-test" do
    server.default("/v1/models", json: models("m"))

    out, _err, status = bootstrap(target, "--dry-run", "--no-test")

    expect(status.exitstatus).to eq(0)
    expect(out).to include("dry run: would write a new file", "  hosts:\n    local:\n")
    expect(File.exist?(config)).to be(false)
    expect(server.requests.map(&:path)).not_to include("/v1/chat/completions")
  end

  it "still writes the config when the test fails, and says so with exit 1" do
    server.default("/v1/models", json: models("m"))
    server.default("/v1/chat/completions", status: 500, json: { error: { message: "out of memory" } })

    out, _err, status = bootstrap(target)

    expect(status.exitstatus).to eq(1)
    expect(out).to include("test: failed: HTTP 500: out of memory", "(new)")
    expect(File.exist?(config)).to be(true)
  end

  it "adds a hosts entry to an existing config, keeping its lines and default.model" do
    original = "# mine\ndefault:\n  model: main:qwen\nhosts:\n  main:\n    host: 10.0.0.2\n"
    FileUtils.mkdir_p(File.dirname(config))
    File.write(config, original)
    server.default("/v1/models", json: models("m"))

    out, _err, status = bootstrap(target, "--no-test")

    expect(status.exitstatus).to eq(0)
    expect(File.read(config)).to eq("#{original}  local:\n    host: \"127.0.0.1\"\n    port: #{server.port}\n    api: \"openai\"\n")
    expect(out).to include("hosts entry 'local' added; backup config.yml.bak-", "use it: chi --model local:m")
    expect(Dir["#{config}.bak-*"].map { |b| File.read(b) }).to eq([original])
  end

  it "says so when the server is configured already" do
    FileUtils.mkdir_p(File.dirname(config))
    File.write(config, "hosts:\n  box:\n    host: 127.0.0.1\n    port: #{server.port}\n    api: openai\n")
    server.default("/v1/models", json: models("m"))

    out, _err, status = bootstrap(target, "--no-test")

    expect(status.exitstatus).to eq(0)
    expect(out).to include("already has this server as 'box'; nothing written", "chi --model box:m")
    expect(Dir["#{config}.bak-*"]).to be_empty
  end

  it "reports a closed port in one line" do
    port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }

    _out, err, status = bootstrap("127.0.0.1:#{port}")

    expect([err, status.exitstatus]).to eq(["chi bootstrap: can't reach 127.0.0.1:#{port} (connection refused)\n", 1])
  end

  it "prints its usage with --help" do
    out, _err, status = bootstrap("--help")

    expect(status.exitstatus).to eq(0)
    expect(out).to start_with("Usage: chi bootstrap [TARGET]")
  end

  it "is in chi --help" do
    out, = Open3.capture3(env, RbConfig.ruby, chi, "--help", stdin_data: "")

    expect(out).to include("chi bootstrap [HOST[:PORT]|URL]")
  end

  context "on a terminal" do
    let(:tty) do
      Class.new(StringIO) { def tty? = true }
    end

    def run_command(input, *args, extra_env: {})
      out = StringIO.new
      err = StringIO.new
      command = Samagotchi::BootstrapCommand.new(args, stdin: tty.new(input), stdout: out, stderr: err,
                                                       env: extra_env, config_path: config)
      [command.run, out.string, err.string]
    end

    it "offers a numbered pick, narrowed by typed text" do
      server.default("/v1/models", json: models(*(1..25).map { |i| "model-#{i}" }, "special-one"))

      code, out, = run_command("special\n", target, "--no-test")

      expect(code).to eq(0)
      expect(out).to include(" 1) model-1", "… 6 more: type part of a name")
      expect(written.dig("default", "model")).to eq("local:special-one")
    end

    it "asks for the key's variable on a 401 and probes again with it" do
      server.enqueue("/v1/models", status: 401, json: { error: { message: "no key" } })
      server.default("/v1/models", json: models("m"))

      code, out, = run_command("FAKE_KEY\n", target, "--no-test", extra_env: { "FAKE_KEY" => "sk-2" })

      expect(code).to eq(0)
      expect(out).to include("API key environment variable")
      expect(written.dig("hosts", "local", "api_key_env")).to eq("FAKE_KEY")
    end
  end
end
