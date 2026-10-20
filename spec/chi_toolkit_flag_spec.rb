# frozen_string_literal: true

require "tmpdir"
require "json"
require "support/fake_provider_server"

# --toolkit NAME, --tool / --no-tool on a session-starting run: saved in the
# new session's file as given, and what its prompt declares. One example
# runs a real bin/chi; the rest fork it (ChiCli#fork_chi).
RSpec.describe "chi --toolkit" do
  it "is listed in --help, with --tool and --no-tool" do
    out, = fork_chi("--help")
    expect(out).to include("--toolkit NAME", "--tool NAME", "--no-tool NAME")
  end

  # One --non-interactive turn against a fake llama.cpp, forked or with
  # +spawn+ a real process: the prompt chi sent and the session file it saved.
  def chi_turn(*args, prompt: "hi", spawn: false)
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "ok", stop: true)}\n\n"])
    saved = nil
    Dir.mktmpdir do |dir|
      env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
              "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_MODEL_PROFILE" => nil,
              "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1", "SAMAGOTCHI_SERVER_PORT" => server.port.to_s }
      _out, err, status = run_or_fork_chi(*args, "--non-interactive", "-p", prompt, spawn: spawn, env: env, chdir: dir)
      raise "chi failed: #{err}" unless status.success?

      file = Dir.glob(File.join(dir, "state", "**", "*.json")).find { |path| File.basename(path, ".json").match?(/\A\h{8}-/) }
      saved = JSON.parse(File.read(file))
    end
    [server.requests.find { |r| r.path == "/completion" }&.json&.[]("prompt"), saved]
  ensure
    server&.stop
  end

  it "saves the toolkit as given and declares only its tools" do
    prompt, saved = chi_turn("--toolkit", "lean", "--tool", "delegate", "--no-tool", "web_fetch", spawn: true)

    expect(saved["toolkit"]).to eq("name" => "lean", "add" => ["delegate"], "remove" => ["web_fetch"])
    expect(prompt).to include('"name": "delegate"')
    expect(prompt).not_to include('"name": "list_sessions"', '"name": "web_fetch"')
    expect(prompt).to include("Not declared in this session (toolkit lean): register_reminder, cancel_reminder, " \
                              "list_reminders, list_sessions, send_note, delegate_result. Search them with find_tools; " \
                              "call one with call_tool. Removed (toolkit lean): web_fetch. Only the user can load it " \
                              "(/toolkit add <name>).")
  end

  it "saves full without the flag, and the prompt has no not-loaded line" do
    prompt, saved = chi_turn

    expect(saved["toolkit"]).to eq("name" => "full", "add" => [], "remove" => [])
    expect(prompt).to include('"name": "list_sessions"')
    expect(prompt).not_to include("Not loaded")
  end

  describe "--no-tool beside other flags" do
    it "leaves a value-taking flag's value alone, a --no-tool-looking prompt too" do
      prompt, saved = chi_turn("--model", "spec-model", "--no-tool", "web_fetch", prompt: "--no-tool=x is broken")
      expect(saved["toolkit"]).to eq("name" => "full", "add" => [], "remove" => ["web_fetch"])
      expect(prompt).to include("--no-tool=x is broken")
    end

    it "refuses a missing name: nothing after it, a flag, or --" do
      [%w[--no-tool], %w[--no-tool --], %w[--no-tool --model x], ["--no-tool="]].each do |args|
        _out, err, status = fork_chi(*args)
        expect(status.exitstatus).to eq(1), "#{args.inspect}: #{err}"
        expect(err).to include("missing argument: --no-tool"), args.inspect
      end
    end
  end
end
