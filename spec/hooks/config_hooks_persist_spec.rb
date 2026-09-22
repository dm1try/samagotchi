# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/engine"
require "samagotchi/session"

# Hooks configured in config.yml are process-scoped: Engine#run_turn clears
# turn-scoped hooks in its ensure block, and that must not wipe configured
# hooks after the first turn (it did, so they only ever fired once).
RSpec.describe Samagotchi::Engine, "config.yml hooks" do
  let(:hooks_dir) { Dir.mktmpdir("config-hooks-") }
  let(:client) do
    dbl = instance_double(Samagotchi::Client)
    allow(dbl).to receive(:complete).and_return(nil)
    dbl
  end

  around do |example|
    orig_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = orig_model
    FileUtils.rm_rf(hooks_dir)
  end

  before do
    $config_hook_turns = 0
    File.write(File.join(hooks_dir, "config_hook_turn_counter.rb"), <<~RUBY)
      class ConfigHookTurnCounter
        def call(_event)
          $config_hook_turns += 1
        end
      end
    RUBY
    allow(Samagotchi::ConfigFile).to receive(:read_yaml).and_call_original
    allow(Samagotchi::ConfigFile).to receive(:read_yaml)
      .with(path: Samagotchi::ConfigFile.global_path)
      .and_return({ "hooks" => { "hooks_dir" => hooks_dir, "before_turn" => [{ "path" => "config_hook_turn_counter.rb" }] } })
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
  end

  it "fires a configured before_turn hook on every turn, not only the first" do
    engine = described_class.new(mode: :assist, client: client)
    allow(engine.instance_variable_get(:@kernel)).to receive(:run) do
      Samagotchi::KernelLoop::Result.new(output: "ok", conversation: [], exhausted: false, pending_tool_calls: false, tool_activity: [])
    end
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)

    engine.run_turn(session, "one")
    engine.run_turn(session, "two")

    expect($config_hook_turns).to eq(2)
  end

  it "still clears hooks registered for a single turn via register_hook" do
    engine = described_class.new(mode: :assist, client: client)
    allow(engine.instance_variable_get(:@kernel)).to receive(:run) do
      Samagotchi::KernelLoop::Result.new(output: "ok", conversation: [], exhausted: false, pending_tool_calls: false, tool_activity: [])
    end
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
    manual = 0
    engine.register_hook(:before_turn) { manual += 1 }

    engine.run_turn(session, "one")
    engine.run_turn(session, "two")

    expect(manual).to eq(1)
    expect($config_hook_turns).to eq(2)
  end
end
