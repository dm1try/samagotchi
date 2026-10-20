# frozen_string_literal: true

require "tmpdir"
require "json"
require "support/fake_provider_server"

# --append-system-prompt FILE on the plain REPL path (--non-interactive): the
# file's text is in the prompt after config.yml's append_system_prompt:
# entries, and the session saves the flag's files (not the config's). A
# file that can't be used stops chi before anything starts. One run is a
# real bin/chi; the rest fork it (ChiCli#fork_chi).
RSpec.describe "chi --append-system-prompt" do
  # One --non-interactive turn against a fake llama.cpp, forked or with
  # +spawn+ a real process, in a temp home +yield+ fills first.
  def chi_turn(*args, config: nil, spawn: false)
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "ok", stop: true)}\n\n"])
    Dir.mktmpdir do |tmp|
      dir = File.realpath(tmp)
      FileUtils.mkdir_p(File.join(dir, "config", "samagotchi"))
      File.write(File.join(dir, "config", "samagotchi", "config.yml"), config) if config
      yield dir if block_given?
      env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
              "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_MODEL_PROFILE" => nil,
              "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1", "SAMAGOTCHI_SERVER_PORT" => server.port.to_s }
      _out, err, status = run_or_fork_chi(*args, "--no-shared", "--non-interactive", "-p", "hi", spawn: spawn, env: env,
                                                                                                   chdir: dir)
      request = server.requests.find { |r| r.path == "/completion" }
      files = Dir.glob(File.join(dir, "state", "**", "*.json")).select { |path| File.basename(path, ".json").match?(/\A\h{8}-/) }
      saved = files.map { |path| JSON.parse(File.read(path)) }.find { |data| data.key?("appended_prompt_files") }
      { dir: dir, status: status, err: err, prompt: request&.json&.fetch("prompt"), saved: saved }
    end
  ensure
    server&.stop
  end

  it "puts the config's files, then the flag's, into the prompt and saves only the flag's" do
    run = chi_turn("--append-system-prompt", "notes/extra.md", config: "append_system_prompt:\n  - CLAUDE.md\n", spawn: true) do |dir|
      FileUtils.mkdir_p(File.join(dir, "notes"))
      File.write(File.join(dir, "notes", "extra.md"), "EXTRA RULES")
      File.write(File.join(dir, "CLAUDE.md"), "CLAUDE RULES")
    end

    expect(run[:status]).to be_success, run[:err]
    expect(run[:prompt]).to include("Appended from ~/CLAUDE.md:\nCLAUDE RULES\n\nAppended from ~/notes/extra.md:\nEXTRA RULES\n")
    expect(run[:saved]["appended_prompt_files"]).to eq([File.join(run[:dir], "notes", "extra.md")])
  end

  it "stops before anything starts on a file that can't be used" do
    run = chi_turn("--append-system-prompt", "gone.md")

    expect(run[:status].exitstatus).to eq(1)
    expect(run[:err]).to include("Error: --append-system-prompt gone.md: no such file")
    expect(run[:prompt]).to be_nil
    expect(run[:saved]).to be_nil
  end

  it "stops with the usual error on a ~user that doesn't exist" do
    run = chi_turn("--append-system-prompt", "~nosuchuser_zz/x.md")

    expect(run[:status].exitstatus).to eq(1)
    expect(run[:err]).to eq("Error: --append-system-prompt ~nosuchuser_zz/x.md: no such user\n")
  end

  it "warns once about a file above 32k chars, and still uses it" do
    run = chi_turn("--append-system-prompt", "big.md") { |dir| File.write(File.join(dir, "big.md"), "x" * 40_000) }

    expect(run[:status]).to be_success, run[:err]
    expect(run[:err].scan("Warning: --append-system-prompt big.md is 40000 chars; it is in every request").size).to eq(1)
    expect(run[:prompt]).to include("Appended from ~/big.md:")
  end
end
