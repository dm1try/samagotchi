# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/session_commands"
require "samagotchi/turn_flow"
require "samagotchi/memory_bundle/installer"

# The shipped mcp bundle and the fake MCP server its specs run
# (mcp_client_spec, mcp_bundle_spec, mcp_bundle_cache_spec).
MCP_SHIPPED = File.expand_path("../../lib/samagotchi/bundles/mcp", __dir__)
MCP_FAKE = File.expand_path("../fixtures/mcp/fake_server.rb", __dir__)

def alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
end

# The shipped mcp bundle (lib/samagotchi/bundles/mcp), installed into an
# Engine: its settings, ENV and the helpers that reach its tools.
RSpec.shared_context "the mcp bundle in an Engine" do
  let(:tmpdir) { Dir.mktmpdir("mcp-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:client) { instance_double(Samagotchi::Client, complete: nil) }
  let(:fake) { { "command" => [RbConfig.ruby, MCP_FAKE] } }
  let(:servers) { { "fake" => fake } }
  let(:settings) { { "servers" => servers, "startup_timeout" => 2, "timeout" => 5 } }
  let(:session_dir) { File.join(tmpdir, "session").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:tiny_png) { File.expand_path("../fixtures/images/tiny.png", __dir__) }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

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
    allow_any_instance_of(Samagotchi::Engine).to receive(:bundle_settings).and_return("mcp" => settings)
    Samagotchi::MemoryBundle::Installer.new(source: MCP_SHIPPED, name: "mcp", scope: "system", strict: true).run
  end

  after do
    @engine&.shutdown
    FileUtils.rm_rf(tmpdir)
  end

  # An Engine whose init tasks (a server's first start) ran, as its first
  # turn sees it: the tasks done, their tools applied.
  def engine
    @engine ||= Samagotchi::Engine.new(client: client).tap do |built|
      @init_events = []
      built.subscribe(observer: ->(e) { @init_events << e })
      built.start_init_tasks!
      built.instance_variable_get(:@plugin_tasks).tasks.each { |task| task.thread&.join(10) }
      built.apply_staged_tools!
    end
  end

  def tools = engine.instance_variable_get(:@tools)

  def call_tool(name, args = {})
    tools[name].handler.call({ name: name, args: args }, nil)
  end

  # Through ToolRunner, with the session's images in +session_dir+.
  def run_tool(name, args = {}, vision: nil)
    kernel = engine.instance_variable_get(:@kernel)
    vision ||= Samagotchi::VisionContext.new(session_dir: session_dir, resizer: Samagotchi::ImageResizer.new(nil))
    kernel.turn_settings = kernel.turn_settings.with(vision: vision)
    Samagotchi::ToolRunner.new(kernel).run({ name: name, args: args }, iteration: 1, call_index: 1, call_count: 1,
                                                                       on_stream_event: nil, max_tool_output_chars: nil)
  end

  # What the Engine's load and init tasks showed: notices and cards.
  def load_events
    engine
    engine.send(:announce_guardrail_failures, ->(e) { @init_events << e })
    @init_events.select { |e| %i[hook_notice card].include?(e[:type]) }
  end

  def server_pid
    engine.instance_variable_get(:@services).to_a.first.value.pid
  end
end
