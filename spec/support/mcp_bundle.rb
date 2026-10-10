# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"
require "samagotchi/engine"
require "samagotchi/llm/chat_loop"
require "samagotchi/session"
require "samagotchi/session_commands"
require "samagotchi/turn_flow"
require "samagotchi/memory_bundle/installer"

# The shipped mcp bundle and the fake MCP server its specs run
# (mcp_client_spec, mcp_bundle_spec, mcp_bundle_cache_spec).
MCP_SHIPPED = File.expand_path("../../lib/samagotchi/bundles/mcp", __dir__)
MCP_FAKE = File.expand_path("../fixtures/mcp/fake_server.rb", __dir__)
# How a spec starts it: without RubyGems and without the RUBYOPT that
# `bundle exec` sets (-rbundler/setup). It needs only the default json, and
# boots in ~0.02 s instead of ~0.25 s; most examples start a server or more.
MCP_FAKE_COMMAND = ["/usr/bin/env", "-u", "RUBYOPT", RbConfig.ruby, "--disable-gems", MCP_FAKE].freeze

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
  let(:fake) { { "command" => MCP_FAKE_COMMAND } }
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

  # An MCP tool through mcp_call (<server>/<tool>).
  def mcp(tool, args = {}, server: "fake")
    call_tool("mcp_call", { "tool" => "#{server}/#{tool}", "args" => args })
  end

  def find(query, server = nil)
    call_tool("find_mcp_tools", { "query" => query, "server" => server }.compact)
  end

  # The mcp bundle's tools in the registry.
  def mcp_tools = tools.entries.select { |entry| entry.source == "mcp" }.map(&:name)

  # mcp_call through ToolRunner, with the session's images in +session_dir+.
  def run_mcp(tool, args = {}, vision: nil)
    run_tool("mcp_call", { "tool" => "fake/#{tool}", "args" => args }, vision: vision)
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

  # The tokens /mcp should estimate for these tools of the server (by the
  # server's names, from its cache): what LLM::ChatLoop#tool_definitions
  # would send for them as tools, its JSON ÷ CHARS_PER_TOKEN.
  def chat_tokens(names, server: "fake")
    cache = File.join(ENV["XDG_STATE_HOME"], "samagotchi", "plugins", "mcp", "tools-#{server}.json")
    listed = JSON.parse(File.read(cache))["tools"].select { |tool| names.include?(tool["name"]) }
    schemas = listed.map do |tool|
      name = "mcp_#{server}_#{tool["name"]}".downcase.gsub(/[^a-z0-9_]+/, "_").squeeze("_")
      Samagotchi::Plugin::Api.tool_spec(name, tool["description"], schema: tool["inputSchema"]) { nil }[:schema]
    end
    definition_tokens(schemas)
  end

  # What find_mcp_tools and mcp_call take in every request, estimated as
  # #chat_tokens.
  def fixed_tokens = definition_tokens(%w[find_mcp_tools mcp_call].map { |name| tools[name].schema })

  def definition_tokens(schemas)
    tools = Samagotchi::Tools::Registry.new
    schemas.each { |schema| tools.register(schema[:name], schema: schema, handler: ->(*) {}, source: "mcp") }
    chat = Samagotchi::LLM::ChatLoop.new(kernel: Struct.new(:tools, :llm_context_layers).new(tools, []))
    chat.tool_definitions.sum { |definition| Samagotchi::TokenUsage.estimate(JSON.generate(definition)) }
  end

  # /mcp's last line.
  def mcp_total(tokens)
    "Every request carries find_mcp_tools and mcp_call: ~#{fixed_tokens} tokens. The tools above, ~#{tokens} tokens, " \
      "reach the model only in a search's answer (estimated: their JSON as the chat API gets it, ÷ 4)."
  end

  def server_pid
    engine.instance_variable_get(:@services).to_a.first.value.pid
  end
end
