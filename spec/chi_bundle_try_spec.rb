# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
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
        sandbox = described_class.new(bundle_at(source), settings: { "hello" => "world" })
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

  it "fails the install with RemovedApi's one line, not a backtrace, for a config naming a removed api" do
    Dir.mktmpdir do |dir|
      source = bundle_at(File.join(dir, "source"))
      user_config = File.join(dir, "user-config")
      FileUtils.mkdir_p(File.join(user_config, "samagotchi"))
      File.write(File.join(user_config, "samagotchi", "config.yml"),
                 "default:\n  model: mac:m\nhosts:\n  mac:\n    url: http://127.0.0.1:1\n    api: omlx\n")

      with_env("XDG_CONFIG_HOME" => user_config) do
        sandbox = described_class.new(source)
        expect { sandbox.install }.to raise_error(
          described_class::Error,
          "chi bundle try: config.yml hosts.mac.api: omlx was removed; for mlx_lm.server or oMLX use " \
          "url: http://HOST:PORT/v1, api: openai in a hosts: entry"
        )
      ensure
        sandbox&.cleanup
      end
    end
  end

  it "stops the delegate workers and tasks a run left in the sandbox, and nothing that isn't running" do
    pids = []
    Dir.mktmpdir do |dir|
      sandbox = described_class.new(bundle_at(File.join(dir, "source")))
      # A delegate's worker: its own session and group, holding its session's lock.
      session_dir = File.join(sandbox.state_home, Samagotchi::Session::STATE_SUBDIR, "delegate-1")
      lib = File.expand_path("../lib", __dir__)
      worker = Process.spawn(RbConfig.ruby, "-I", lib, "-rsamagotchi/owner_lock", "-e",
                             "Samagotchi::OwnerLock.acquire(#{session_dir.inspect}, kind: 'worker'); sleep 30",
                             pgroup: true)
      Process.detach(worker)
      pids << worker
      wait_until!("the worker's lock", timeout: 10) do
        Samagotchi::OwnerLock.owner(session_dir)&.pid == worker
      end
      # A task the turn started, by its record.
      task = Process.spawn("sleep", "30", pgroup: true)
      Process.detach(task)
      pids << task
      record = Samagotchi::Tools::TaskRecord.running(
        id: "task-1", command: "sleep 30", cwd: sandbox.work_dir, pid: task,
        pid_started: Samagotchi::ProcessGroup.start_time(task), started_at: Time.now.iso8601,
        output_path: "out", exit_code_path: "code"
      )
      task_dir = File.join(sandbox.work_dir, Samagotchi::Tools::TaskRuntime::TASKS_DIR, "task-1")
      FileUtils.mkdir_p(task_dir)
      File.write(File.join(task_dir, Samagotchi::Tools::TaskRuntime::METADATA_FILENAME), JSON.generate(record.to_file))
      # A finished task's record names a pid that isn't signalled.
      done_dir = File.join(sandbox.work_dir, Samagotchi::Tools::TaskRuntime::TASKS_DIR, "task-2")
      FileUtils.mkdir_p(done_dir)
      File.write(File.join(done_dir, Samagotchi::Tools::TaskRuntime::METADATA_FILENAME),
                 JSON.generate(record.with(id: "task-2", status: "completed", pid: Process.pid).to_file))
      allow(Process).to receive(:kill).and_call_original

      sandbox.stop_leftovers

      expect(wait_until(timeout: 5) { pids.all? { |pid| process_gone?(pid) } }).to be(true)
      expect(Process).not_to have_received(:kill).with(anything, Process.pid)
      expect(Process).not_to have_received(:kill).with(anything, -Process.pid)
      sandbox.cleanup
    end
  ensure
    pids.each { |pid| Process.kill("KILL", pid) unless process_gone?(pid) }
  end

  it "leaves a running task record's group alone without a start time, or with another process's" do
    foreign = Process.spawn("sleep", "30", pgroup: true)
    Process.detach(foreign)
    Dir.mktmpdir do |dir|
      sandbox = described_class.new(bundle_at(File.join(dir, "source")))
      tasks = File.join(sandbox.work_dir, Samagotchi::Tools::TaskRuntime::TASKS_DIR)
      base = Samagotchi::Tools::TaskRecord.running(
        id: "task-1", command: "sleep 30", cwd: sandbox.work_dir, pid: foreign, pid_started: nil,
        started_at: Time.now.iso8601, output_path: "out", exit_code_path: "code"
      )
      # A hand-over not adopted yet (no start time), and a pid reused since.
      { "unadopted" => base, "reused" => base.with(id: "reused", pid_started: "Mon Jan  1 00:00:00 2001") }
        .each do |id, record|
          FileUtils.mkdir_p(File.join(tasks, id))
          File.write(File.join(tasks, id, Samagotchi::Tools::TaskRuntime::METADATA_FILENAME),
                     JSON.generate(record.to_file))
        end
      allow(Samagotchi::ProcessGroup).to receive(:stop).and_call_original

      sandbox.stop_leftovers

      expect(Samagotchi::ProcessGroup).not_to have_received(:stop)
      expect(process_gone?(foreign)).to be(false)
      sandbox.cleanup
    end
  ensure
    Process.kill("KILL", -foreign) if foreign && !process_gone?(foreign)
  end

  describe "chi bundle try" do
    include ChiCli

    # Hang protection only: these turns end on their own, and the example's
    # own limit (spec_helper) comes after it. A tight one is a flake on a
    # loaded runner (the child boots chi and installs three bundles first).
    def run_timeout = "100"

    # `chi bundle try ARGS` in this process (as bin/chi runs it) with +env+:
    # one chi boot fewer than run_chi; the sandbox's child is a real chi.
    # @return [Array(String, String, Integer)] stdout, stderr, exit status
    def try_here(*args, env:)
      out = StringIO.new
      err = StringIO.new
      status = with_env(env) do
        Samagotchi::BundleCommand.new(["try", *args], stdin: StringIO.new(""), stdout: out, stderr: err).run
      end
      [out.string, err.string, status]
    end

    it "requires exactly one bundle path and a prompt" do
      Dir.mktmpdir do |dir|
        # One spawn for bin/chi's dispatch and exit status.
        _out, err, status = run_chi("bundle", "try", env: isolated_chi_env(dir), chdir: dir)
        expect(status.exitstatus).to eq(2)
        expect(err).to include("Usage: chi bundle try PATH")

        _out, err, status = try_here(File.join(dir, "missing"), "-p", "run", env: isolated_chi_env(dir))
        expect(status).to eq(2)
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
        out, err, status = try_here(source, "-p", "test failure", "--timeout", run_timeout, env: env)

        expect(status).to eq(1)
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

        # Through bin/chi once, end to end.
        out, err, status = run_chi("bundle", "try", source, "-p", "say PONG", "--timeout", run_timeout,
                                   env: env, chdir: dir)

        expect(status.exitstatus).to eq(0), err
        expect(out).to include("answer:\n  PONG\n")
        expect(err).to include("cost-cap> warning: the $1.00 cap can't be enforced")
        expect(err).not_to include("Session:")
        expect(server.requests.map(&:path)).to include("/completion")
        expect(File.read(user_config)).to eq(original_config)
        expect(File.read(user_state)).to eq(original_state)

        json_out, json_err, json_status = try_here(source, "-p", "say PONG", "--json", "--timeout", run_timeout,
                                                   "--memory", "foo", "--mute", "bar", "--set", "cost-cap.cap=2",
                                                   "--keep", env: env)
        report = JSON.parse(json_out)
        kept_root = json_err[/^sandbox: (.+)$/, 1]
        expect(json_status).to eq(0), json_err
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
      Dir.mktmpdir do |dir|
        source = bundle_at(File.join(dir, "source"))
        env = isolated_chi_env(dir, "SAMAGOTCHI_DEFAULT_MODEL" => "oai:spec-model")
        config = File.join(env.fetch("XDG_CONFIG_HOME"), "samagotchi", "config.yml")
        FileUtils.mkdir_p(File.dirname(config))
        File.write(config, "hosts:\n  oai:\n    host: 127.0.0.1\n    port: #{server.port}\n    api: openai\n")

        # --json prints the text trace on stderr: one run checks both.
        json_out, json_err, json_status = try_here(source, "-p", "push it", "--timeout", run_timeout, "--json",
                                                   env: env)
        expect(json_status).to eq(0), json_err
        expect(json_err).to include("execute          denied", "git push origin main")
        report = JSON.parse(json_out)
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
        # Ctrl-C keeps the turn's finished iterations: the call is saved,
        # with its arguments, and shows once.
        expect(report["tools"]).to eq([{ "index" => 1, "name" => "execute", "args" => "echo hi", "status" => "ok",
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
        # As Bridge::CardStore saves it.
        File.write(File.join(session_dir, "cards.json"), JSON.generate(
          "version" => 1, "turns" => 1, "entries" => [
            { "type" => "hook_notice", "hook" => "fixture.rb", "text" => "hook ran", "turns" => 0 },
            { "type" => "question", "pending_question" => { "question" => "Continue?" },
              "cancelled" => true, "reason" => "non_interactive", "turns" => 0 },
            { "type" => "card", "title" => "Fixture", "body" => "card body", "turns" => 0 }
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

    it "shows a timed-out turn's saved calls once each, the one it cut short as interrupted" do
      Dir.mktmpdir do |state_home|
        write_trace_session(state_home, "trace-timeout", [
          { "role" => "user", "content" => "go" },
          { "role" => "model", "content" => "", "tool_calls" => [
            { "id" => "call-1", "name" => "execute", "arguments" => { "command" => "ls" } },
            { "id" => "call-2", "name" => "execute", "arguments" => { "command" => "sleep 9" } }
          ] },
          { "role" => "tool_response", "tool_call_id" => "call-1", "content" => "[execute]\nok" },
          { "role" => "tool_response", "tool_call_id" => "call-2",
            "content" => Samagotchi::ToolResponse.interrupted_text("execute") },
          { "role" => "system", "content" => "[SYSTEM: the previous turn was cancelled (ctrl-c).]" }
        ], [{ "iteration" => 1, "call_index" => 1, "tool" => "execute", "status" => "ok", "duration_ms" => 5 }])

        trace = described_class.new(state_home: state_home, session_id: "trace-timeout")
                               .read(exit_code: 1, answer: "", stderr: "", sandbox: nil, timed_out: true)

        expect(trace.tools).to eq([
          { index: 1, name: "execute", args: "ls", status: "ok", duration_ms: 5 },
          { index: 2, name: "execute", args: "sleep 9", status: "interrupted", duration_ms: 0 }
        ])
        expect(trace.timed_out).to be(true)
      end
    end

    it "marks an aliased call cut short interrupted (saved as the model's name, answered as the tool's)" do
      Dir.mktmpdir do |state_home|
        write_trace_session(state_home, "trace-alias", [
          { "role" => "user", "content" => "go" },
          { "role" => "model", "content" => "", "tool_calls" => [
            { "id" => "call-1", "name" => "bash", "arguments" => { "command" => "sleep 9" } }
          ] },
          { "role" => "tool_response", "tool_call_id" => "call-1",
            "content" => Samagotchi::ToolResponse.interrupted_text("execute") }
        ], [])

        trace = described_class.new(state_home: state_home, session_id: "trace-alias")
                               .read(exit_code: 1, answer: "", stderr: "", sandbox: nil, timed_out: true)

        expect(trace.tools).to eq([{ index: 1, name: "bash", args: "sleep 9", status: "interrupted", duration_ms: 0 }])
      end
    end

    describe Samagotchi::BundleCommand::Try::Run do
      it "forwards an interrupt received while the child is starting" do
        previous = Signal.trap("INT") {}
        Dir.mktmpdir do |dir|
          sandbox = Struct.new(:child_env, :work_dir).new({}, dir)
          # The child is a bare sleep, not a Ruby: an INT that reaches a
          # Ruby still loading its prelude (rubygems, RUBYOPT's
          # bundler/setup) ends it with status 1, not by the signal, and
          # the forwarded INT lands there whenever the boot is slow.
          allow(Open3).to receive(:popen3).and_wrap_original do |original, env, *_command, **kwargs, &block|
            Process.kill("INT", Process.pid)
            original.call(env, "sleep", "30", **kwargs, &block)
          end

          result = described_class.new(sandbox).run(prompt: "test", options: {}, timeout: 0.5)

          expect(result.exit_status).to eq(130)
          expect(result.timed_out).to be(false)
        end
      ensure
        Signal.trap("INT", previous)
      end

      it "exits 130 when a forwarded Ctrl-C ends a child still booting with status 1" do
        previous = Signal.trap("INT") {}
        Dir.mktmpdir do |dir|
          ready = File.join(dir, "ready")
          # A Ruby interrupted while loading its prelude exits 1, not by
          # the signal: this child does the same.
          sandbox = stub_child(dir, <<~RUBY)
            trap("INT") { exit 1 }
            File.write(#{ready.inspect}, "")
            sleep 30
          RUBY
          interrupter = Thread.new do
            wait_until!("the child", timeout: 10) { File.exist?(ready) }
            Process.kill("INT", Process.pid)
          end

          result = described_class.new(sandbox).run(prompt: "test", options: {}, timeout: 30)

          interrupter.join
          expect(result.exit_status).to eq(130)
          expect(result.timed_out).to be(false)
        end
      ensure
        Signal.trap("INT", previous)
      end

      it "exits 130 when a Ctrl-C held while starting ends the child with status 1" do
        previous = Signal.trap("INT") {}
        Dir.mktmpdir do |dir|
          sandbox = Struct.new(:child_env, :work_dir).new({}, dir)
          # The child exits 1 as a booting Ruby would; the INT itself is
          # held back so no shell race decides the status.
          allow(Samagotchi::ProcessGroup).to receive(:signal)
          allow(Open3).to receive(:popen3).and_wrap_original do |original, env, *_command, **kwargs, &block|
            Process.kill("INT", Process.pid)
            original.call(env, "sh", "-c", "sleep 0.2; exit 1", **kwargs, &block)
          end

          result = described_class.new(sandbox).run(prompt: "test", options: {}, timeout: 5)

          expect(result.exit_status).to eq(130)
          expect(Samagotchi::ProcessGroup).to have_received(:signal).with(anything, "INT")
        end
      ensure
        Signal.trap("INT", previous)
      end

      it "keeps the child's own failure when no Ctrl-C reached it" do
        Dir.mktmpdir do |dir|
          sandbox = stub_child(dir, "exit 1\n")

          result = described_class.new(sandbox).run(prompt: "test", options: {}, timeout: 5)

          expect(result.exit_status).to eq(1)
        end
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
          # The descendant holds the pipes: the readers' grace runs out.
          stub_const("#{described_class}::READER_GRACE", 0.3)
          sandbox = Struct.new(:child_env, :work_dir).new({}, dir)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          result = described_class.new(sandbox).run(prompt: "test", options: {}, timeout: 5)

          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          descendant_pid = Integer(File.read(pid_file))
          expect(result.exit_status).to eq(0)
          expect(result.stdout).to include("child started")
          expect(elapsed).to be < 4
          expect(wait_until(timeout: 2) { process_gone?(descendant_pid) }).to be(true)
        end
      end

      def stub_child(dir, source)
        script = File.join(dir, "chi_stub.rb")
        File.write(script, source)
        stub_const("Samagotchi::BundleCommand::Try::Sandbox::CHI", script)
        stub_const("Samagotchi::BundleCommand::Try::Sandbox::LIB_DIR", dir)
        Struct.new(:child_env, :work_dir).new({}, dir)
      end

      it "signals no process group after a child that exited with nothing left in its group" do
        Dir.mktmpdir do |dir|
          sandbox = stub_child(dir, "puts 'done'\n")
          allow(Process).to receive(:kill).and_call_original

          result = described_class.new(sandbox).run(prompt: "test", options: {}, timeout: 5)

          expect(result.exit_status).to eq(0)
          # kill(0) only asks; no signal goes to a group.
          expect(Process).not_to have_received(:kill).with(satisfy { |signal| signal != 0 },
                                                           satisfy { |pid| pid.is_a?(Integer) && pid.negative? })
        end
      end

      it "stops the groups the child started (a task's) when the turn times out" do
        task_pid = nil
        Dir.mktmpdir do |dir|
          pid_file = File.join(dir, "task.pid")
          sandbox = stub_child(dir, <<~RUBY)
            trap("INT") {}
            pid = Process.spawn("sleep", "30", pgroup: true)
            File.write(#{pid_file.inspect}, pid)
            sleep 30
          RUBY
          stub_const("#{described_class}::INTERRUPT_GRACE", 0.2)
          run = described_class.new(sandbox)
          allow(run).to receive(:wait_for).and_wrap_original do |wait_for, wait, seconds|
            # The turn's wait ends once the task runs, not on the clock.
            wait_until!("the task", timeout: 10) { File.size?(pid_file) || !wait.alive? } if seconds == 600
            wait_for.call(wait, seconds == 600 ? 0 : seconds)
          end

          result = run.run(prompt: "test", options: {}, timeout: 600)

          task_pid = Integer(File.read(pid_file))
          expect(result.timed_out).to be(true)
          expect(wait_until(timeout: 3) { process_gone?(task_pid) }).to be(true)
        end
      ensure
        Process.kill("KILL", task_pid) if task_pid && !process_gone?(task_pid)
      end
    end
  end
end
