# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/tools/builtins"

# A participant's turn runs execute without the variables whose names hold
# a secret, and a command still running at the limit is killed, never handed
# over as a background task; the owner's turns run as configured.
RSpec.describe Samagotchi::Tools::Builtins, "a participant's execute" do
  let(:home) { Dir.mktmpdir("pair-execute-home") }

  around { |example| with_env("HOME" => home, "PAIR_PROBE_API_KEY" => "sk-x", "PAIR_PROBE_PLAIN" => "y") { example.run } }
  after { FileUtils.rm_rf(home) }

  def kctx(mode)
    peers = Struct.new(:session_id, :model_ref, :thinking, :reasoning_history).new("s1", "m", nil, nil)
    Struct.new(:peers, :participant_mode, :cancel_controller, :reminder_store).new(peers, mode, nil, nil)
  end

  def run_as(mode)
    seen = nil
    allow(Samagotchi::Tools::Execute).to receive(:call) { |_command, **opts| seen = opts and "ok" }
    described_class.registry["execute"].handler.call({ name: "execute", content: "env" }, kctx(mode))
    seen
  end

  it "scrubs secret-named variables and kills at the limit in a participant's turn" do
    opts = run_as(:pair)
    expect(opts[:on_timeout]).to eq(:kill)
    expect(opts[:env]).to include("PAIR_PROBE_API_KEY" => nil)
    expect(opts[:env]).not_to have_key("PAIR_PROBE_PLAIN")
    expect(run_as(:review)[:on_timeout]).to eq(:kill)
  end

  describe "the session's project env (ProjectEnv)" do
    before { Samagotchi::ProjectEnv.install!(Samagotchi::ProjectEnv::NONE.with(env: { "PATH" => "/project/bin:/usr/bin:/bin", "PROJECT_PROBE" => "a", "GEM_HOME" => nil }.freeze)) }
    after { Samagotchi::ProjectEnv.reset! }

    it "reaches the owner's execute and task_create, never a participant's execute" do
      expect(run_as(nil)[:env]).to include("PROJECT_PROBE" => "a", "PATH" => "/project/bin:/usr/bin:/bin", "GEM_HOME" => nil)
      pair_env = run_as(:pair)[:env]
      expect(pair_env.keys).not_to include("PROJECT_PROBE", "PATH", "GEM_HOME")
      marker = described_class.task_marker_env(kctx(nil), { "PROJECT_PROBE" => "mine" })
      expect(marker).to include("PATH" => "/project/bin:/usr/bin:/bin")
      expect(marker).not_to have_key("PROJECT_PROBE")
      expect(described_class.task_marker_env(kctx(:pair), nil).keys).not_to include("PATH", "PROJECT_PROBE")
    end

    it "is what an owner's command sees, for real" do
      out = Samagotchi::Tools::Execute.call("printf %s \"$PROJECT_PROBE\"", cwd: home, env: described_class.project_env(kctx(nil)))
      expect(out).to include("a")
    end
  end

  it "leaves the owner's turns as they were" do
    opts = run_as(nil)
    expect(opts).not_to have_key(:on_timeout)
    expect(opts[:env]).not_to have_key("PAIR_PROBE_API_KEY")
  end

  it "runs the command without them, for real" do
    out = Samagotchi::Tools::Execute.call("printf %s \"$PAIR_PROBE_API_KEY|$PAIR_PROBE_PLAIN\"", cwd: home,
                                          env: Samagotchi::Guardrails::PairBoundary.scrubbed_env, on_timeout: :kill)
    expect(out).to include("|y")
    expect(out).not_to include("sk-x")
  end
end
