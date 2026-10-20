# frozen_string_literal: true

require "tmpdir"
require "json"
require "support/fake_provider_server"

# --parent-answers LEVEL on a session-starting run: the session's own
# guardrails.parent_answers, saved in its file; it may only tighten
# config.yml's (a looser one warns). One example runs a real bin/chi; the
# rest fork it (ChiCli#fork_chi).
RSpec.describe "chi --parent-answers" do
  it "is listed in --help; config.yml's key has no flag of its own" do
    out, = fork_chi("--help")
    expect(out).to include("--parent-answers LEVEL")
    expect(out).not_to include("--guardrails-parent-answers")
  end

  # One --non-interactive turn against a fake llama.cpp, forked or with
  # +spawn+ a real process: the session file it saved and stderr.
  def chi_turn(*args, config: nil, spawn: false)
    server = FakeProviderServer.start
    server.default("/completion", sse: ["data: #{JSON.generate(content: "ok", stop: true)}\n\n"])
    Dir.mktmpdir do |dir|
      if config
        FileUtils.mkdir_p(File.join(dir, "config", "samagotchi"))
        File.write(File.join(dir, "config", "samagotchi", "config.yml"), config)
      end
      env = { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
              "SAMAGOTCHI_DEFAULT_MODEL" => "spec-model", "SAMAGOTCHI_MODEL_PROFILE" => nil,
              "SAMAGOTCHI_SERVER_HOST" => "127.0.0.1", "SAMAGOTCHI_SERVER_PORT" => server.port.to_s }
      _out, err, status = run_or_fork_chi(*args, "--non-interactive", "-p", "hi", spawn: spawn, env: env, chdir: dir)
      raise "chi failed: #{err}" unless status.success?

      file = Dir.glob(File.join(dir, "state", "**", "*.json")).find { |path| File.basename(path, ".json").match?(/\A\h{8}-/) }
      return [JSON.parse(File.read(file)), err]
    end
  ensure
    server&.stop
  end

  it "saves the level in the new session; none without the flag" do
    saved, err = chi_turn("--parent-answers", "standard", spawn: true)
    expect(saved["parent_answers"]).to eq("standard")
    expect(err).not_to include("looser")

    saved, = chi_turn
    expect(saved["parent_answers"]).to be_nil
  end

  it "warns when config.yml's is stricter, and saves it as given" do
    saved, err = chi_turn("--parent-answers", "soft", config: "guardrails:\n  parent_answers: hard\n")
    expect(saved["parent_answers"]).to eq("soft")
    expect(err).to include("--parent-answers soft is looser than config.yml's guardrails.parent_answers: hard; hard applies")
  end

  it "takes a level in any case" do
    saved, = chi_turn("--parent-answers", "STANDARD")
    expect(saved["parent_answers"]).to eq("standard")
  end

  it "refuses a value that isn't a level (an abbreviation too), exit 2, and chi web" do
    %w[loose sof].each do |word|
      _out, err, status = fork_chi("--parent-answers", word)
      expect(status.exitstatus).to eq(2), word
      expect(err).to include("--parent-answers takes hard, standard, soft, not #{word}")
    end

    _out, err, status = fork_chi("web", "--parent-answers", "hard")
    expect(status.exitstatus).to eq(2)
    expect(err).to include("--parent-answers is a new session's")
  end
end
