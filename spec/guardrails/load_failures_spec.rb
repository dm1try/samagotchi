# frozen_string_literal: true

require "samagotchi/guardrails"
require "samagotchi/engine"

RSpec.describe Samagotchi::Guardrails::LoadFailures do
  let(:failures) { described_class.new }
  let(:verdict) { Samagotchi::Guardrails::Verdict.new(call: { name: "read", content: "x" }) }

  it "lets calls through with no required failure, and has no message with none" do
    failures.add("hook a.rb (config)", "LoadError: x", required: false)
    expect(failures.check(verdict)).to be_allow
    expect(described_class.new.message).to be_nil
  end

  it "denies every call while a required guardrail failed to load, naming it" do
    failures.add("hook guard.rb (bundle g)", "the file is missing", required: true)
    failures.check(verdict)
    expect(verdict.deny_text).to start_with(
      "denied by guardrail (rule guardrail-load, core): required guardrail hook guard.rb (bundle g) failed to load: the file is missing."
    )
    expect(failures.message).to eq("hook guard.rb (bundle g) failed to load (the file is missing). Every tool call is denied until it is fixed")
  end
end

RSpec.describe "Engine: guardrail load failures" do
  let(:dir) { Dir.mktmpdir("engine-lf") }
  let(:config_path) { Samagotchi::ConfigFile.global_path }
  let!(:original) { File.read(config_path) }

  after do
    File.write(config_path, original)
    Samagotchi::ConfigFile.instance_variable_set(:@yaml_cache, nil)
    FileUtils.rm_rf(dir)
  end

  it "denies every tool call when a required config hook is missing, and announces it once" do
    File.write(config_path, original + <<~YAML)
      hooks:
        hooks_dir: #{dir}
        before_tool_call:
          - path: gone_guard_hook.rb
            required: true
    YAML
    Samagotchi::ConfigFile.instance_variable_set(:@yaml_cache, nil)
    engine = nil
    expect { engine = Samagotchi::Engine.new(mode: :assist, client: instance_double(Samagotchi::Client)) }
      .to output(/gone_guard_hook.rb failed to load/).to_stderr
    gate = engine.instance_variable_get(:@kernel).guardrail_gate
    verdict = gate.evaluate({ name: "read", content: "README.md" }, iteration: 1, params: "")
    expect(verdict).to be_deny
    expect(verdict.rule).to eq("guardrail-load")

    events = []
    2.times { engine.send(:announce_guardrail_failures, ->(e) { events << e }) }
    expect(events.map { |e| e[:type] }).to eq([:guardrail_warning])
    expect(events.first[:message]).to include("gone_guard_hook.rb (config) failed to load")
  end
end
