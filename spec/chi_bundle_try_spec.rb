# frozen_string_literal: true

require "fileutils"
require "json"
require "samagotchi/bundle_command/try/sandbox"
require "support/chi_cli"
require "support/fake_provider_server"

RSpec.describe Samagotchi::BundleCommand::Try::Sandbox do
  def bundle_at(dir, name: "try-fixture")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "manifest.yml"), <<~YAML)
      name: #{name}
      version: 0.1.0
      scope: system
    YAML
    dir
  end

  it "filters code and memory configuration while keeping model and runtime settings" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "source")
      config_home = File.join(dir, "user-config")
      config_dir = File.join(config_home, "samagotchi")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "config.yml"), <<~YAML)
        default:
          model: local:fixture
        hosts:
          local:
            url: http://127.0.0.1:1234
        llm_context:
          strategy: stale
        retry:
          max: 0
        bundles:
          user's-bundle:
            setting: true
        hooks:
          session_start: [run-me]
        guardrails:
          rules: risky.yml
        memories: [private]
        append_system_prompt: [private.md]
        context:
          sources: [private-source]
          window_tokens: 1234
      YAML

      with_env("XDG_CONFIG_HOME" => config_home) do
        sandbox = described_class.new(bundle_at(source), bundle_settings: { "hello" => "world" })
        copied = YAML.safe_load_file(File.join(sandbox.config_home, "samagotchi", "config.yml"))
        expect(copied.dig("default", "model")).to eq("local:fixture")
        expect(copied.dig("hosts", "local", "url")).to eq("http://127.0.0.1:1234")
        expect(copied.dig("llm_context", "strategy")).to eq("stale")
        expect(copied.dig("retry", "max")).to eq(0)
        expect(copied["hooks"]).to be_nil
        expect(copied["guardrails"]).to be_nil
        expect(copied["memories"]).to be_nil
        expect(copied["append_system_prompt"]).to be_nil
        expect(copied.dig("context", "sources")).to be_nil
        expect(copied.dig("context", "window_tokens")).to eq(1234)
        expect(copied.dig("bundles", "try-fixture", "hello")).to eq("world")
        expect(copied.dig("bundles", "cost-cap", "cap")).to eq(1)
        sandbox.cleanup
      end
    end
  end

  it "builds a child environment without mutating ENV or inheriting parent markers" do
    Dir.mktmpdir do |dir|
      source = bundle_at(File.join(dir, "source"))
      with_env(
        "SAMAGOTCHI_DEFAULT_MODEL" => "user-model",
        "SAMAGOTCHI_PARENT_SESSION" => "parent-id",
        "SAMAGOTCHI_GUARDRAILS_TEST" => "deny",
        "SAMAGOTCHI_LOG_FILE" => "/tmp/user.log",
        "SAMAGOTCHI_SESSION_SHARED" => "true"
      ) do
        sandbox = described_class.new(source)
        expect(sandbox.child_env["SAMAGOTCHI_DEFAULT_MODEL"]).to eq("user-model")
        expect(sandbox.child_env["SAMAGOTCHI_PARENT_SESSION"]).to be_nil
        expect(sandbox.child_env["SAMAGOTCHI_GUARDRAILS_TEST"]).to be_nil
        expect(sandbox.child_env["SAMAGOTCHI_LOG_FILE"]).to be_nil
        expect(sandbox.child_env["SAMAGOTCHI_SESSION_SHARED"]).to be_nil
        expect(sandbox.child_env["SAMAGOTCHI_KEYCHAIN"]).to eq("on")
        expect(sandbox.child_env["XDG_CONFIG_HOME"]).to eq(sandbox.config_home)
        expect(sandbox.child_env["XDG_STATE_HOME"]).to eq(sandbox.state_home)
        expect(ENV["SAMAGOTCHI_PARENT_SESSION"]).to eq("parent-id")
        sandbox.cleanup
      end
    end
  end

  it "installs the tried bundle and sandbox guards without touching a same-named user bundle" do
    Dir.mktmpdir do |dir|
      source = bundle_at(File.join(dir, "source"))
      user_config = File.join(dir, "user-config")
      user_bundle = File.join(user_config, "samagotchi", "memories", ".bundles", "try-fixture", "untouched")
      FileUtils.mkdir_p(File.dirname(user_bundle))
      File.write(user_bundle, "do not change")
      File.write(File.join(user_config, "samagotchi", "config.yml"), "default:\n  model: local:fixture\n")

      with_env("XDG_CONFIG_HOME" => user_config) do
        sandbox = described_class.new(source)
        sandbox.install
        expect(File.read(user_bundle)).to eq("do not change")
        installed = File.join(sandbox.config_home, "samagotchi", "memories", ".bundles")
        expect(Dir.children(installed).sort).to include("try-fixture", "guardrails", "cost-cap")
        sandbox.cleanup
      end
    end
  end

  describe "chi bundle try" do
    include ChiCli

    it "requires exactly one bundle path and a prompt" do
      Dir.mktmpdir do |dir|
        _out, err, status = run_chi("bundle", "try", env: isolated_chi_env(dir), chdir: dir)
        expect(status.exitstatus).to eq(2)
        expect(err).to include("Usage: chi bundle try PATH")

        _out, err, status = run_chi("bundle", "try", File.join(dir, "missing"), "-p", "run",
                                    env: isolated_chi_env(dir), chdir: dir)
        expect(status.exitstatus).to eq(2)
        expect(err).to include("isn't a folder")
      end
    end

    it "runs one prompt with the inherited model settings in the sandbox child" do
      server = FakeProviderServer.start
      server.default("/completion", sse: ["data: #{JSON.generate(content: "PONG", stop: true)}\n\n"])
      Dir.mktmpdir do |dir|
        source = bundle_at(File.join(dir, "source"))
        env = isolated_chi_env(
          dir,
          "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model",
          "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1",
          "SAMAGOTCHI_SERVER_PORT" => server.port.to_s,
          "SAMAGOTCHI_RETRY_MAX" => "0"
        )
        out, err, status = run_chi("bundle", "try", source, "-p", "say PONG", "--timeout", "20",
                                   env: env, chdir: dir)

        expect(status.exitstatus).to eq(0), err
        expect(out).to eq("PONG\n")
        expect(err).to match(/\ASession: \S+\n/)
        expect(server.requests.map(&:path)).to include("/completion")
      end
    ensure
      server&.stop
    end
  end
end
