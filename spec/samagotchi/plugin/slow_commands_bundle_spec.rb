# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "samagotchi/guardrails"
require "samagotchi/engine"
require "samagotchi/tool_runner"
require "samagotchi/memory_bundle/installer"

# The slow-commands bundle (lib/samagotchi/bundles/slow-commands) installed and
# loaded by an Engine (its plugin alone: lib/samagotchi/bundles/slow-commands/spec/).
RSpec.describe "The slow-commands bundle" do
  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/slow-commands", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("slow-commands-") }
  let(:project) { File.join(tmpdir, "repo").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:timed_out) { "Error: command timed out after 120s\n(killed at the limit; for a long command use task_create, then task_wait)" }

  after { FileUtils.rm_rf(tmpdir) }

  def execute(command, cwd: nil) = { name: "execute", content: command, cwd: cwd }.compact

  # Installed as a user would, loaded by an Engine: its hooks vote through
  # the real Gate in ToolRunner, with after_tool_call's call:, elapsed_ms:
  # and result: from ToolRunner itself.
  describe "the shipped bundle" do
    let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
    let(:client) { instance_double(Samagotchi::Client, complete: nil) }
    let(:engine) { Samagotchi::Engine.new(client: client) }
    let(:hooks) { engine.instance_variable_get(:@hooks) }
    let(:output) { ["[execute]\n#{timed_out}"] }
    let(:runner) do
      out = output
      kernel = Struct.new(:hooks, :tools, :guardrail_gate) do
        define_method(:dispatch_tool_call) { |c| { output: out.first, activity: { tool: c[:name], status: "error" } } }
      end
      Samagotchi::ToolRunner.new(kernel.new(hooks))
    end

    around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

    around do |example|
      saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME")
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
      ENV["XDG_STATE_HOME"] = File.join(tmpdir, "state")
      Dir.chdir(project) { example.run }
    ensure
      %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
    end

    before do
      # requires_chi names the release that carries after_tool_call's new keys.
      stub_const("Samagotchi::VERSION", "0.59.0")
      FileUtils.mkdir_p(system_dir)
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      @installer = Samagotchi::MemoryBundle::Installer.new(source: shipped, name: "slow-commands", scope: "system", strict: true)
      @installer.run
    end

    def run(c) = runner.run(c, iteration: 1, call_index: 1, call_count: 1, on_stream_event: ->(_) {}, max_tool_output_chars: nil)

    it "installs cleanly and loads" do
      expect(@installer.warnings).to be_empty
      expect(engine.guardrail_failures.any?).to be false
    end

    it "records a timed-out execute, denies the next identical one once, and lets the second through" do
      hooks.fire(:before_turn, { type: :before_turn, prompt: "test" })
      expect(run(execute("bundle exec rspec")).output).to start_with("[execute]\nError: command timed out")
      hooks.fire(:before_turn, { type: :before_turn, prompt: "again" })
      expect(run(execute("bundle exec rspec")).output)
        .to start_with("[execute] Error: denied by guardrail (bundle slow-commands): slow command. ")
      expect(run(execute("bundle exec rspec")).output).to start_with("[execute]\nError: command timed out")
    end
  end
end
