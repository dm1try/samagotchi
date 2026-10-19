# frozen_string_literal: true

require "fileutils"
require "json"
require "samagotchi/bundle_command"
require "samagotchi/bundle_command/try/sandbox"
require "support/chi_cli"
require "support/fake_provider_server"
require "samagotchi/bundle_command/try/trace"
require "samagotchi/bundle_command/try/run"

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
        "SAMAGOTCHI_SERVER_HOST" => "model-server",
        "SAMAGOTCHI_PARENT_SESSION" => "parent-id",
        "SAMAGOTCHI_GUARDRAILS_TEST" => "deny",
        "SAMAGOTCHI_LOG_FILE" => "/tmp/user.log",
        "SAMAGOTCHI_SESSION_SHARED" => "true",
        "SAMAGOTCHI_SESSION_RETENTION_DAYS" => "2",
        "SAMAGOTCHI_MEMORIES" => "private",
        "SAMAGOTCHI_APPEND_SYSTEM_PROMPT" => "private.md",
        "SAMAGOTCHI_RECAP_MODEL" => "private-model",
        "SAMAGOTCHI_RECAP_ENABLED" => "true",
        "SAMAGOTCHI_BROADCAST_THRESHOLD" => "0.9",
        "SAMAGOTCHI_WORKER_PROCESS" => "1",
        "SAMAGOTCHI_WORKER_DETACH" => "1",
        "SAMAGOTCHI_BOOT_FALLBACK" => "user-fallback"
      ) do
        sandbox = described_class.new(source)
        expect(sandbox.child_env["SAMAGOTCHI_DEFAULT_MODEL"]).to eq("user-model")
        expect(sandbox.child_env["SAMAGOTCHI_SERVER_HOST"]).to eq("model-server")
        expect(sandbox.child_env["SAMAGOTCHI_PARENT_SESSION"]).to be_nil
        expect(sandbox.child_env["SAMAGOTCHI_GUARDRAILS_TEST"]).to be_nil
        expect(sandbox.child_env["SAMAGOTCHI_LOG_FILE"]).to be_nil
        expect(sandbox.child_env.values_at("SAMAGOTCHI_SESSION_SHARED", "SAMAGOTCHI_SESSION_RETENTION_DAYS",
                                           "SAMAGOTCHI_MEMORIES", "SAMAGOTCHI_APPEND_SYSTEM_PROMPT",
                                           "SAMAGOTCHI_RECAP_MODEL", "SAMAGOTCHI_BROADCAST_THRESHOLD")).to all(be_nil)
        expect(sandbox.child_env["SAMAGOTCHI_RECAP_ENABLED"]).to eq("false")
        expect(sandbox.child_env.values_at("SAMAGOTCHI_WORKER_PROCESS", "SAMAGOTCHI_WORKER_DETACH",
                                           "SAMAGOTCHI_BOOT_FALLBACK")).to all(be_nil)
        expect(sandbox.child_env["SAMAGOTCHI_KEYCHAIN"]).to eq("on")
        expect(sandbox.child_env["XDG_CONFIG_HOME"]).to eq(sandbox.config_home)
        expect(sandbox.child_env["XDG_STATE_HOME"]).to eq(sandbox.state_home)
        expect(ENV["SAMAGOTCHI_PARENT_SESSION"]).to eq("parent-id")
        sandbox.cleanup
      end
    end
  end

  it "removes the temporary root when sandbox initialization fails" do
    Dir.mktmpdir do |dir|
      source = bundle_at(File.join(dir, "source"))
      root = File.join(dir, "incomplete-sandbox")
      FileUtils.mkdir_p(root)
      allow(Dir).to receive(:mktmpdir).with("chi-bundle-try-").and_return(root)
      allow(Samagotchi::ConfigFile).to receive(:read_yaml).and_raise(IOError, "config failure")

      expect { described_class.new(source) }.to raise_error(IOError, "config failure")
      expect(File).not_to exist(root)
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

    it "prints a trace and exits 1 when the child cannot reach its model server" do
      Dir.mktmpdir do |dir|
        source = bundle_at(File.join(dir, "source"))
        env = isolated_chi_env(
          dir,
          "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model",
          "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1",
          "SAMAGOTCHI_SERVER_PORT" => "9",
          "SAMAGOTCHI_RETRY_MAX" => "0"
        )
        out, err, status = run_chi("bundle", "try", source, "-p", "test failure", "--timeout", "20",
                                   env: env, chdir: dir)

        expect(status.exitstatus).to eq(1)
        expect(out).to include("tools:\n", "answer:\n", "exit 1  (")
        expect(err).to include("can't reach host")
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
        user_config = File.join(env.fetch("XDG_CONFIG_HOME"), "samagotchi", "config.yml")
        user_state = File.join(env.fetch("XDG_STATE_HOME"), "samagotchi", "sessions", "existing.json")
        FileUtils.mkdir_p(File.dirname(user_config))
        FileUtils.mkdir_p(File.dirname(user_state))
        File.write(user_config, "bundles:\n  try-fixture:\n    private: true\nhooks:\n  session_start: [private]\n")
        File.write(user_state, "preserve this session")
        original_config = File.read(user_config)
        original_state = File.read(user_state)

        out, err, status = run_chi("bundle", "try", source, "-p", "say PONG", "--timeout", "20",
                                   env: env, chdir: dir)

        expect(status.exitstatus).to eq(0), err
        expect(out).to include("answer:\n  PONG\n")
        expect(err).to include("cost-cap> warning: the $1.00 cap can't be enforced")
        expect(err).not_to include("Session:")
        expect(server.requests.map(&:path)).to include("/completion")
        expect(File.read(user_config)).to eq(original_config)
        expect(File.read(user_state)).to eq(original_state)

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

    it "prints a denied tool call in the trace and JSON report" do
      server = FakeProviderServer.start
      tool_call = {
        "choices" => [{ "index" => 0, "delta" => { "tool_calls" => [
          { "index" => 0, "id" => "call-push", "type" => "function",
            "function" => { "name" => "execute", "arguments" => JSON.generate(command: "git push origin main") } }
        ] } }]
      }
      finish = { "choices" => [{ "index" => 0, "delta" => {}, "finish_reason" => "tool_calls" }] }
      response = [tool_call, finish].map { |event| "data: #{JSON.generate(event)}\n\n" }.join + "data: [DONE]\n\n"
      text = { "choices" => [{ "index" => 0, "delta" => { "content" => "denied" }, "finish_reason" => "stop" }] }
      text_response = ["data: #{JSON.generate(text)}\n\n", "data: [DONE]\n\n"]
      server.enqueue("/v1/chat/completions", sse: response)
      server.enqueue("/v1/chat/completions", sse: text_response)
      server.enqueue("/v1/chat/completions", sse: response)
      server.enqueue("/v1/chat/completions", sse: text_response)
      Dir.mktmpdir do |dir|
        source = bundle_at(File.join(dir, "source"))
        env = isolated_chi_env(dir, "SAMAGOTCHI_DEFAULT_MODEL" => "oai:spec-model")
        config = File.join(env.fetch("XDG_CONFIG_HOME"), "samagotchi", "config.yml")
        FileUtils.mkdir_p(File.dirname(config))
        File.write(config, "hosts:\n  oai:\n    host: 127.0.0.1\n    port: #{server.port}\n    api: openai\n")

        out, err, status = run_chi("bundle", "try", source, "-p", "push it", "--timeout", "20",
                                   env: env, chdir: dir)
        expect(status.exitstatus).to eq(0), err
        expect(out).to include("execute          denied", "git push origin main")

        json_out, json_err, json_status = run_chi("bundle", "try", source, "-p", "push it", "--timeout", "20",
                                                  "--json", env: env, chdir: dir)
        report = JSON.parse(json_out)
        expect(json_status.exitstatus).to eq(0), json_err
        expect(report.dig("tools", 0, "status")).to eq("denied")
        expect(report["denied"]).to eq([1])
        expect(report["timed_out"]).to be(false)
      end
    ensure
      server&.stop
    end

    it "prints the partial trace and timed_out when the child turn times out" do
      server = FakeProviderServer.start
      tool_call = {
        "choices" => [{ "index" => 0, "delta" => { "tool_calls" => [
          { "index" => 0, "id" => "call-echo", "type" => "function",
            "function" => { "name" => "execute", "arguments" => JSON.generate(command: "echo hi") } }
        ] } }]
      }
      finish = { "choices" => [{ "index" => 0, "delta" => {}, "finish_reason" => "tool_calls" }] }
      response = [tool_call, finish].map { |event| "data: #{JSON.generate(event)}\n\n" }.join + "data: [DONE]\n\n"
      started = { "choices" => [{ "index" => 0, "delta" => { "content" => "thinking" } }] }
      server.enqueue("/v1/chat/completions", sse: response)
      server.enqueue("/v1/chat/completions", sse: ["data: #{JSON.generate(started)}\n\n"], hold: true)
      # The --timeout wait ends once the held second request arrives (the
      # tool ran, its record is kept), not on the clock: a loaded machine
      # can't interrupt the child before then.
      allow(Samagotchi::BundleCommand::Try::Run).to receive(:new).and_wrap_original do |make, *args|
        make.call(*args).tap do |run|
          allow(run).to receive(:wait_for).and_wrap_original do |wait_for, wait, seconds|
            if seconds == 600
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
              sleep 0.05 until server.requests.count { |request| request.path == "/v1/chat/completions" } >= 2 ||
                               !wait.alive? ||
                               Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              seconds = 0
            end
            wait_for.call(wait, seconds)
          end
        end
      end
      Dir.mktmpdir do |dir|
        source = bundle_at(File.join(dir, "source"))
        env = isolated_chi_env(dir, "SAMAGOTCHI_DEFAULT_MODEL" => "oai:spec-model", "SAMAGOTCHI_RETRY_MAX" => "0")
        config = File.join(env.fetch("XDG_CONFIG_HOME"), "samagotchi", "config.yml")
        FileUtils.mkdir_p(File.dirname(config))
        File.write(config, "hosts:\n  oai:\n    host: 127.0.0.1\n    port: #{server.port}\n    api: openai\n")
        out = StringIO.new
        err = StringIO.new

        status = with_env(env) do
          Samagotchi::BundleCommand.new(["try", source, "-p", "say hi", "--timeout", "600", "--json"],
                                        stdin: StringIO.new(""), stdout: out, stderr: err).run
        end

        expect(status).to eq(1)
        expect(out.string).not_to be_empty, err.string
        report = JSON.parse(out.string)
        expect(report["timed_out"]).to be(true)
        expect(report["session_id"]).not_to be_nil
        # Ctrl-C keeps only the messages before the turn: the call comes
        # from its tool record, without arguments.
        expect(report["tools"]).to eq([{ "index" => 1, "name" => "execute", "args" => "", "status" => "ok",
                                         "duration_ms" => report.dig("tools", 0, "duration_ms") }])
        expect(err.string).to include("tools:\n  1 execute          ok", "timed out after 600.0 seconds")
      end
    ensure
      server&.release
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
            { "iteration" => 1, "call_index" => 1, "tool" => "execute", "status" => "error", "duration_ms" => 120 }
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

    it "keeps every assistant call and joins records by iteration and call index" do
      Dir.mktmpdir do |state_home|
        id = "trace-missing-record"
        sessions = File.join(state_home, "samagotchi", "sessions")
        session_dir = File.join(sessions, id)
        FileUtils.mkdir_p(session_dir)
        File.write(File.join(sessions, "#{id}.json"), JSON.generate(
          "messages" => [
            { "role" => "model", "tool_calls" => [
              { "id" => "call-missing", "name" => "execute", "arguments" => { "command" => "git push origin main" } },
              { "id" => "call-unknown", "name" => "read", "arguments" => { "path" => "unknown.txt" } },
              { "id" => "call-later", "name" => "read", "arguments" => { "path" => "later.txt" } }
            ] },
            { "role" => "tool_response", "tool_call_id" => "call-missing",
              "content" => "No one to approve it (non-interactive run)." },
            { "role" => "tool_response", "tool_call_id" => "call-unknown", "content" => "not denied" },
            { "role" => "tool_response", "tool_call_id" => "call-later", "content" => "file contents" },
            { "role" => "model", "tool_calls" => [
              { "id" => "call-next-iteration", "name" => "write", "arguments" => { "path" => "next.txt" } }
            ] }
          ]
        ))
        File.write(File.join(session_dir, "analytics.json"), JSON.generate(
          "tool_records" => [
            { "iteration" => 1, "call_index" => 3, "tool" => "read", "status" => "ok", "duration_ms" => 22 },
            { "iteration" => 2, "call_index" => 1, "tool" => "write", "status" => "error", "duration_ms" => 33 }
          ]
        ))

        trace = described_class.new(state_home: state_home, session_id: id)
                               .read(exit_code: 0, answer: "done", stderr: "", sandbox: nil)

        expect(trace.tools).to eq([
          { index: 1, name: "execute", args: "git push origin main", status: "denied", duration_ms: 0 },
          { index: 2, name: "read", args: "unknown.txt", status: "unknown", duration_ms: 0 },
          { index: 3, name: "read", args: "later.txt", status: "ok", duration_ms: 22 },
          { index: 4, name: "write", args: "next.txt", status: "error", duration_ms: 33 }
        ])
        expect(trace.denied).to eq([1])
      end
    end

    def write_trace_session(state_home, id, messages, records)
      sessions = File.join(state_home, "samagotchi", "sessions")
      FileUtils.mkdir_p(File.join(sessions, id))
      File.write(File.join(sessions, "#{id}.json"), JSON.generate("messages" => messages))
      File.write(File.join(sessions, id, "analytics.json"), JSON.generate("tool_records" => records))
    end

    it "adds no row for a record a retry's iteration skews on a run that didn't time out" do
      Dir.mktmpdir do |state_home|
        # Iteration 1 was cut and retried: the call ran in the loop's
        # iteration 2, the first saved model message.
        write_trace_session(state_home, "trace-retry", [
          { "role" => "user", "content" => "go" },
          { "role" => "model", "tool_calls" => [
            { "id" => "call-1", "name" => "execute", "arguments" => { "command" => "ls" } }
          ] },
          { "role" => "tool_response", "tool_call_id" => "call-1", "content" => "ok" },
          { "role" => "model", "content" => "done" }
        ], [{ "iteration" => 2, "call_index" => 1, "tool" => "execute", "status" => "ok", "duration_ms" => 5 }])

        trace = described_class.new(state_home: state_home, session_id: "trace-retry")
                               .read(exit_code: 0, answer: "done", stderr: "", sandbox: nil)

        expect(trace.tools).to eq([{ index: 1, name: "execute", args: "ls", status: "unknown", duration_ms: 0 }])
        expect(trace.timed_out).to be(false)
      end
    end

    it "adds the records past the saved messages as rows when the run timed out" do
      Dir.mktmpdir do |state_home|
        write_trace_session(state_home, "trace-timeout", [
          { "role" => "user", "content" => "go" },
          { "role" => "system", "content" => "[SYSTEM: the previous turn was cancelled (ctrl-c).]" }
        ], [
          { "iteration" => 1, "call_index" => 1, "tool" => "execute", "status" => "ok", "duration_ms" => 5 },
          { "iteration" => 2, "call_index" => 1, "called_as" => "rg", "duration_ms" => 7 }
        ])

        trace = described_class.new(state_home: state_home, session_id: "trace-timeout")
                               .read(exit_code: 1, answer: "", stderr: "", sandbox: nil, timed_out: true)

        expect(trace.tools).to eq([
          { index: 1, name: "execute", args: "", status: "ok", duration_ms: 5 },
          { index: 2, name: "rg", args: "", status: "unknown", duration_ms: 7 }
        ])
        expect(trace.timed_out).to be(true)
      end
    end

    describe Samagotchi::BundleCommand::Try::Run do
      it "forwards an interrupt received while the child is starting" do
        previous = Signal.trap("INT") {}
        Dir.mktmpdir do |dir|
          script = File.join(dir, "chi_stub.rb")
          File.write(script, "sleep 30\n")
          stub_const("Samagotchi::BundleCommand::Try::Sandbox::CHI", script)
          stub_const("Samagotchi::BundleCommand::Try::Sandbox::LIB_DIR", dir)
          sandbox = Struct.new(:child_env, :work_dir).new({}, dir)
          allow(Open3).to receive(:popen3).and_wrap_original do |original, *args, **kwargs, &block|
            Process.kill("INT", Process.pid)
            original.call(*args, **kwargs, &block)
          end

          result = described_class.new(sandbox).run(prompt: "test", options: {}, timeout: 0.5)

          expect(result.exit_status).to eq(130)
          expect(result.timed_out).to be(false)
        end
      ensure
        Signal.trap("INT", previous)
      end

      it "returns promptly and kills a descendant that keeps stdout open" do
        Dir.mktmpdir do |dir|
          script = File.join(dir, "chi_stub.rb")
          pid_file = File.join(dir, "descendant.pid")
          File.write(script, <<~RUBY)
            pid = Process.spawn("sleep", "30", out: $stdout, err: $stderr)
            File.write(#{pid_file.inspect}, pid)
            puts "child started"
          RUBY
          stub_const("Samagotchi::BundleCommand::Try::Sandbox::CHI", script)
          stub_const("Samagotchi::BundleCommand::Try::Sandbox::LIB_DIR", dir)
          sandbox = Struct.new(:child_env, :work_dir).new({}, dir)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          result = described_class.new(sandbox).run(prompt: "test", options: {}, timeout: 5)

          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          descendant_pid = Integer(File.read(pid_file))
          expect(result.exit_status).to eq(0)
          expect(result.stdout).to include("child started")
          expect(elapsed).to be < 4
          wait_until(timeout: 2) do
            Process.kill(0, descendant_pid)
            false
          rescue Errno::ESRCH
            true
          end
        end
      end
    end
  end
end
