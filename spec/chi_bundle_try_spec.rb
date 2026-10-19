# frozen_string_literal: true

require "fileutils"
require "json"
require "samagotchi/bundle_command/try/sandbox"
require "support/chi_cli"
require "support/fake_provider_server"
require "samagotchi/bundle_command/try/trace"

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
      kept_root = nil
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
        expect(out).to include("answer:\n  PONG\n")
        expect(err).to include("cost-cap> warning: the $1.00 cap can't be enforced")
        expect(err).not_to include("Session:")
        expect(server.requests.map(&:path)).to include("/completion")

        json_out, json_err, json_status = run_chi("bundle", "try", source, "-p", "say PONG", "--json",
                                                  "--timeout", "20", "--memory", "foo", "--mute", "bar",
                                                  "--set", "cost-cap.cap=2", "--keep", env: env, chdir: dir)
        report = JSON.parse(json_out)
        kept_root = json_err[/^sandbox: (.+)$/, 1]
        expect(json_status.exitstatus).to eq(0), json_err
        expect(json_out.lines.size).to eq(1)
        expect(report.keys).to include("session_id", "exit_code", "answer", "tools", "notices", "cards", "questions",
                                       "interactive_blocked", "used_memories", "tokens", "cost", "model", "sandbox",
                                       "denied", "stderr_tail")
        expect(report["answer"]).to eq("PONG\n")
        expect(report["model"]).to eq("spec-model")
        expect(json_err).to include("tools:")
        expect(File).to exist(kept_root)
        saved = JSON.parse(File.read(File.join(kept_root, "state", "samagotchi", "sessions",
                                               "#{report["session_id"]}.json")))
        expect(saved["preloaded_memory_names"]).to eq(["foo"])
        expect(saved["muted_memory_names"]).to eq(["bar"])
        config = YAML.safe_load_file(File.join(kept_root, "config", "samagotchi", "config.yml"))
        expect(config.dig("bundles", "cost-cap", "cap")).to eq(2)
      end
    ensure
      FileUtils.rm_rf(kept_root) if kept_root
      server&.stop
    end
  end

  describe Samagotchi::BundleCommand::Try::TraceReader do
    it "joins saved tool timing to calls and reports hook notices, unanswerable questions and denials" do
      Dir.mktmpdir do |state_home|
        id = "trace-fixture"
        sessions = File.join(state_home, "samagotchi", "sessions")
        session_dir = File.join(sessions, id)
        FileUtils.mkdir_p(session_dir)
        File.write(File.join(sessions, "#{id}.json"), JSON.generate(
          "model_name" => "host:model", "used_memory_names" => ["preloaded"],
          "messages" => [
            { "role" => "model", "tool_calls" => [
              { "id" => "call-1", "name" => "execute", "arguments" => { "command" => "git push" } }
            ] },
            { "role" => "tool_response", "tool_call_id" => "call-1",
              "content" => "No one to approve it (non-interactive run)." },
            { "role" => "model", "content" => "done" }
          ]
        ))
        File.write(File.join(session_dir, "analytics.json"), JSON.generate(
          "tokens" => { "prompt_sum" => 120, "completion_sum" => 8, "cost_sum" => 0,
                        "cost_estimate_sum" => 0.025 },
          "tool_records" => [
            { "iteration" => 1, "call_index" => 0, "tool" => "execute", "status" => "error", "duration_ms" => 120 }
          ]
        ))
        File.write(File.join(session_dir, "cards.json"), JSON.generate(
          "entries" => [
            { "type" => "hook_notice", "hook" => "fixture.rb", "text" => "hook ran" },
            { "type" => "question", "pending_question" => { "question" => "Continue?" },
              "cancelled" => true, "reason" => "non_interactive" },
            { "type" => "card", "title" => "Fixture", "body" => "card body" }
          ]
        ))

        trace = described_class.new(state_home: state_home, session_id: id)
                               .read(exit_code: 0, answer: "done\n", stderr: "Session: #{id}\n", sandbox: nil)
        expect(trace.tools).to eq([{ index: 1, name: "execute", args: "git push", status: "denied", duration_ms: 120 }])
        expect(trace.denied).to eq([1])
        expect(trace.interactive_blocked).to be(true)
        expect(trace.notices.first["text"]).to eq("hook ran")
        expect(trace.cards.first["title"]).to eq("Fixture")
        expect(trace.questions.first["reason"]).to eq("non_interactive")
        expect(trace.used_memories).to eq(["preloaded"])
        expect(trace.tokens).to eq(prompt: 120, completion: 8)
        expect(trace.cost).to eq(0.025)
        expect(trace.cost_is_estimate).to be(true)
        expect(trace.model).to eq("host:model")
        expect(trace.stderr_tail).to eq("Session: #{id}\n")
      end
    end
  end
end
