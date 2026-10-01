# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/engine"
require "samagotchi/tool_runner"
require "samagotchi/tool_call_parser"
require "samagotchi/memory_bundle/installer"

# The shipped loop-guard bundle (lib/samagotchi/bundles/loop-guard),
# installed as a user would and loaded by an Engine; its hooks vote through
# the real Gate in ToolRunner. The turn-by-turn behaviour is in
# loop_guard_replay_spec.rb.
RSpec.describe "The loop-guard bundle" do
  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/loop-guard", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("loop-guard-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  let(:client) { instance_double(Samagotchi::Client, complete: nil) }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["XDG_STATE_HOME"] = File.join(tmpdir, "state")
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  before do
    FileUtils.mkdir_p(system_dir)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    @installer = Samagotchi::MemoryBundle::Installer.new(source: shipped, name: "loop-guard", scope: "system", strict: true)
    @installer.run
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  let(:engine) { Samagotchi::Engine.new(client: client) }
  let(:hooks) { engine.instance_variable_get(:@hooks) }
  let(:runner) do
    kernel = Struct.new(:hooks) do
      def dispatch_tool_call(call) = { output: "[#{call[:name]}]\nexit: 0 (no output)", activity: { tool: call[:name], status: "ok" } }
    end
    Samagotchi::ToolRunner.new(kernel.new(hooks))
  end

  def run(call)
    runner.run(call, iteration: 1, call_index: 1, call_count: 1, on_stream_event: ->(_) {}, max_tool_output_chars: nil)
  end

  it "installs cleanly, with no memory" do
    expect(@installer.warnings).to be_empty
    expect(engine.guardrail_failures.any?).to be false
    index = File.join(system_dir, "index.md")
    expect(File.exist?(index) ? File.read(index) : "").not_to include("loop-guard")
  end

  it "denies the 3rd identical call with the same result, through the Gate, and before_turn resets it" do
    find = { name: "execute", content: "find . -name 'config.yml' 2>/dev/null" }
    hooks.fire(:before_turn, { type: :before_turn, prompt: "update my config" })
    outputs = Array.new(3) { run(find.dup)[:output] }

    expect(outputs[0, 2]).to all(eq("[execute]\nexit: 0 (no output)"))
    expect(outputs[2]).to start_with("[execute] Error: denied by guardrail (bundle loop-guard): repeated call. ")
    expect(outputs[2]).to include("You already ran this exact call 2 times this turn", "(exit: 0 (no output))")

    hooks.fire(:before_turn, { type: :before_turn, prompt: "try again" })
    expect(run(find.dup)[:output]).to eq("[execute]\nexit: 0 (no output)")
  end

  it "keys an edit by its old and new text: different edits to one file are not repeats" do
    gemma = Samagotchi::ToolCallParser::Gemma.new(Samagotchi::ModelProfile.gemma4)
    d = '<|"|>'
    edit = ->(old) { gemma.parse("<|tool_call>call:edit{path:#{d}a.rb#{d},old_text:#{d}#{old}#{d},new_text:#{d}x#{d}}<tool_call|>").first }
    hooks.fire(:before_turn, { type: :before_turn, prompt: "edit" })

    expect(%w[a b c].map { |old| run(edit.(old))[:output] }).to all(start_with("[edit]\nexit: 0"))
    expect(run(edit.("c"))[:output]).to start_with("[edit]\nexit: 0")
    expect(run(edit.("c"))[:output]).to start_with("[edit] Error: denied by guardrail (bundle loop-guard): repeated call. ")
  end
end
