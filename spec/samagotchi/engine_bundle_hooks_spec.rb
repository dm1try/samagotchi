# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/memory_bundle/provenance"
require "support/test_kernel"
require "support/legacy_hooks_record"

# An installed record that still has class-file hooks (a 0.157 install):
# chi loads none of them.
RSpec.describe Samagotchi::Engine, "class-file bundle hooks" do
  let(:tmpdir) { Dir.mktmpdir("engine-bundle-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }
  let(:client) do
    dbl = test_client
    allow(dbl).to receive(:complete).and_return(nil)
    dbl
  end

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  before do
    FileUtils.mkdir_p(system_dir)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def first_turn_events(engine)
    allow(engine.instance_variable_get(:@kernel)).to receive(:run) do
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: [], exhausted: false, pending_tool_calls: false, tool_activity: [])
    end
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
    events = []
    engine.run_turn(session, "hi", on_event: ->(event) { events << event })
    events
  end

  it "loads none of a record's hooks, tool calls still running" do
    LegacyHooksRecord.legacy_hooks_record(
      "old-guard", hooks: { "guard.rb" => { text: "class Guard; def call(e) = e[:guardrail].deny!('old guard'); end\n",
                                            meta: { "event" => "before_tool_call", "on_error" => "fail_closed" } } }
    )
    engine = described_class.new(client: client)

    hooks = engine.instance_variable_get(:@hooks)
    expect(hooks.bundle_hook_names(:before_tool_call)).to eq([])
    verdict = Samagotchi::Guardrails::Verdict.new(call: { name: "execute" })
    engine.guardrail_failures.check(verdict)
    expect(verdict).not_to be_deny

    expect(first_turn_events(engine).map { |event| event[:type] }).not_to include(:guardrail_warning)
  end

  it "says nothing for a record whose hooks/ dir is empty, or with no bundles dir" do
    LegacyHooksRecord.legacy_hooks_record("ported", hooks: {})
    FileUtils.mkdir_p(File.join(bundles_dir, "ported", "hooks"))
    expect(first_turn_events(described_class.new(client: client)).map { |event| event[:type] }).not_to include(:guardrail_warning)

    FileUtils.rm_rf(bundles_dir)
    expect { described_class.new(client: client) }.not_to raise_error
  end
end
