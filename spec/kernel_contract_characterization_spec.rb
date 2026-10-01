# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "tmpdir"
require "yaml"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/terminal_ui"
require "samagotchi/memory_bundle/installer"
require_relative "support/fake_provider_server"
require_relative "support/fake_chat_adapter"
require_relative "support/recording_surface"

# What the Engine and its KernelLoop agree on, end to end, through real
# objects only: a real Engine builds its real KernelLoop, real Clients talk
# to a fake llama.cpp over HTTP (/completion, /props), and the chat host's
# adapter is a FakeChatAdapter that says it is local (remote? false). It pins
# the per-turn settings the kernel carries (vision, sampling, thinking, the
# model name), the tool flows that reach the Engine (muted memory_read,
# ask_user_question, the reminder store), a model switch between turns, and
# the TUI's wiring (its kernel's store, hooks and tools are the Engine's).
RSpec.describe "Kernel contract (characterization)" do
  # A chat adapter on a local server: the window comes from the kernel's
  # client (/props), as for a llama.cpp chat host.
  let(:local_chat_adapter) do
    Class.new(FakeChatAdapter) do
      def remote? = false
    end
  end

  let(:tmp) { Dir.mktmpdir("kernel-contract") }
  let(:server) { FakeProviderServer.start }
  let(:png) { File.expand_path("fixtures/images/tiny.png", __dir__) }
  let(:logs) { [] }
  let(:registry) { Samagotchi::HostRegistry.new }
  let(:qwen_props) do
    { "chat_template" => "<|im_start|> <function=", "default_generation_settings" => { "n_ctx" => 32_768 } }
  end

  around do |example|
    FakeProviderServer.without_webmock do
      with_config_home(File.join(tmp, "config")) do
        with_env("XDG_STATE_HOME" => File.join(tmp, "state")) { example.run }
      end
    end
  ensure
    server.stop
    FileUtils.rm_rf(tmp)
  end

  before do
    File.write(File.join(tmp, "config", "samagotchi", "config.yml"), YAML.dump(
      "default" => { "model" => "box:Qwen3.6" },
      "hosts" => {
        "box" => { "host" => "127.0.0.1", "port" => server.port },
        "oai" => { "host" => "127.0.0.1", "port" => server.port, "api" => "openai" }
      },
      "models" => {
        "Qwen3.6" => { "sampling" => { "temperature" => 0.3 }, "thinking" => "off" },
        "chat-model" => { "sampling" => { "temperature" => 0.2, "top_k" => 20 }, "thinking" => "off", "vision" => true },
        "chat-two" => { "sampling" => { "temperature" => 0.7 } }
      }
    ))
    server.default("/props", json: qwen_props)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(Samagotchi::Log).to receive(:level?).and_return(true)
    allow(Samagotchi::Log).to receive(:debug) { |tag, event, **fields| logs << [tag, event, fields] }
  end

  def session_for(model)
    Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: tmp)
  end

  def chat_adapter(*steps)
    local_chat_adapter.new(*steps).tap do |adapter|
      allow(registry).to receive(:adapter_for).and_return(adapter)
    end
  end

  def sse(*pieces)
    pieces.map { |piece| "data: #{JSON.generate(content: piece, stop: false)}\n\n" } +
      ["data: #{JSON.generate(content: "", stop: true)}\n\n"]
  end

  def qwen_call(name, **params)
    body = params.map { |key, value| "<parameter=#{key}>\n#{value}\n</parameter>\n" }.join
    "<tool_call>\n<function=#{name}>\n#{body}</function>\n</tool_call>"
  end

  def completions = server.requests.select { |request| request.path == "/completion" }

  def dumps(event) = logs.select { |tag, name, _| tag == :model && name == event }.map(&:last)

  def tool_messages(request) = request[:messages].select { |message| message[:role] == "tool" }

  describe "a chat turn" do
    let(:engine) { Samagotchi::Engine.new(host_registry: registry, model_name: "oai:chat-model") }

    it "sends the model's sampling under its thinking fields, the prompt's image and a tool's image" do
      adapter = chat_adapter(FakeChatAdapter.tools(["c1", "read", { "path" => png }]), FakeChatAdapter.text("two squares"))

      result = engine.run_turn(session_for("oai:chat-model"), "what's this?", images: [{ path: png }])

      expect(result.output).to eq("two squares")
      expect(adapter.requests.map { |request| request[:model] }).to eq(%w[chat-model chat-model])
      expect(adapter.requests.map { |request| request[:options] }).to all(eq(
        chat_template_kwargs: { enable_thinking: false }, reasoning_effort: "none", temperature: 0.2, top_k: 20
      ))
      user = adapter.requests.first[:messages].reverse.find { |message| message[:role] == "user" }
      expect(user[:content].map { |part| part[:type] }).to eq(%w[text image_url])
      expect(user[:content].last[:image_url][:url]).to start_with("data:image/png;base64,")
      tool_images = adapter.requests.last[:messages].last
      expect(tool_images[:role]).to eq("user")
      expect(tool_images[:content].first).to eq(type: "text", text: "[images from tool results]")
      expect(tool_images[:content].last[:type]).to eq("image_url")
      expect(dumps("tool_call").map { |fields| [fields[:tool], fields[:model]] }).to eq([%w[read chat-model]])
    end

    it "refuses a muted memory, hands ask_user_question to the question handler, and keeps a reminder in the Engine's store" do
      engine = Samagotchi::Engine.new(host_registry: registry, model_name: "oai:chat-model", muted_memories: ["secret"])
      asked = []
      engine.set_question_sync_handler { |pending| asked << pending; { selected: ["Dogs"] } }
      adapter = chat_adapter(
        FakeChatAdapter.tools(["c1", "memory_read", { "name" => "secret" }],
                              ["c2", "ask_user_question", { "question" => "Which pet?", "options" => %w[Cats Dogs] }],
                              ["c3", "register_reminder", { "name" => "tea", "description" => "brew it", "interval_minutes" => 5 }]),
        FakeChatAdapter.text("done")
      )

      engine.run_turn(session_for("oai:chat-model"), "go")

      outputs = tool_messages(adapter.requests.last).map { |message| message[:content] }
      expect(outputs[0]).to eq("[memory_read]\nError: memory 'secret' is muted for this session")
      expect(asked.map { |pending| pending.slice(:question, :options) }).to eq([{ question: "Which pet?", options: %w[Cats Dogs] }])
      expect(outputs[1]).to start_with("[ask_user_question]\n").and include("Dogs")
      expect(outputs[2]).to start_with("[register_reminder]\n")
      expect(engine.reminder_store.reminders.keys).to eq(["tea"])
      expect(engine.reminder_store.reminders["tea"]).to include(description: "brew it", interval_minutes: 5)
    end

    it "follows a model switch between turns: the request and the tool dumps name the new model" do
      adapter = chat_adapter(FakeChatAdapter.tools(["c1", "list_reminders", {}]), FakeChatAdapter.text("one"),
                             FakeChatAdapter.tools(["c2", "list_reminders", {}]), FakeChatAdapter.text("two"))
      session = session_for("oai:chat-model")

      engine.run_turn(session, "first")
      engine.switch_model!("oai:chat-two")
      engine.run_turn(session, "second")

      expect(adapter.requests.map { |request| request[:model] }).to eq(%w[chat-model chat-model chat-two chat-two])
      expect(adapter.requests.last[:options]).to eq(temperature: 0.7)
      expect(dumps("tool_call").map { |fields| fields[:model] }).to eq(%w[chat-model chat-two])
    end
  end

  describe "a native turn" do
    let(:engine) { Samagotchi::Engine.new(host_registry: registry) }
    let(:client) { registry.entries["box"].client }

    it "asks the host's Client with the sampling, stops, model, cancel controller and retry callback, after the empty thought" do
      server.enqueue("/completion", sse: sse("Hello."))
      allow(client).to receive(:complete).and_call_original

      result = engine.run_turn(session_for("box:Qwen3.6"), "hi")

      expect(result.output).to eq("Hello.")
      expect(client).to have_received(:complete).once.with(
        a_string_ending_with(Samagotchi::Thinking::QWEN_EMPTY_THOUGHT),
        sampling: { temperature: 0.3 }, stop: Samagotchi::ModelProfile.normalize("qwen36").stop_sequences,
        model: "Qwen3.6", on_chunk: kind_of(Proc), on_retry: kind_of(Proc),
        cancel_controller: kind_of(Samagotchi::CancellationController)
      )
      body = completions.last.json
      expect(body).to include("temperature" => 0.3, "model" => "Qwen3.6")
      expect(body["prompt"]).to end_with(Samagotchi::Thinking::QWEN_EMPTY_THOUGHT)
    end

    it "runs the tool flows through the native loop too" do
      engine = Samagotchi::Engine.new(host_registry: registry, muted_memories: ["secret"])
      server.enqueue("/completion", sse: sse(qwen_call("memory_read", name: "secret")))
      server.enqueue("/completion", sse: sse(qwen_call("register_reminder", name: "tea", description: "brew it", interval_minutes: 5)))
      server.enqueue("/completion", sse: sse("done"))

      engine.run_turn(session_for("box:Qwen3.6"), "go")

      expect(completions[1].json["prompt"]).to include("Error: memory 'secret' is muted for this session")
      expect(engine.reminder_store.reminders.keys).to eq(["tea"])
      expect(dumps("tool_call").map { |fields| [fields[:tool], fields[:model]] })
        .to eq([%w[memory_read Qwen3.6], %w[register_reminder Qwen3.6]])
    end
  end

  describe "the TUI's Engine" do
    let(:surface) { RecordingSurface.new }

    before do
      source = <<~RUBY
        class Plugin
          def initialize(_settings) = nil

          def register(chi)
            chi.tool("contract_echo", "Echo text back.", params: { text: { type: "string" } }) { |args, _ctx| "echo: \#{args["text"]}" }
            chi.on(:before_generation) { |event| (Thread.current[:contract_generations] ||= []) << event[:iteration] }
          end
        end
      RUBY
      src = File.join(tmp, "src-contract")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "plugin.rb"), source)
      File.write(File.join(src, "manifest.yml"), YAML.dump(
        "name" => "contract", "version" => "1.0.0", "files" => {},
        "plugin" => { "file" => "plugin.rb", "sha256" => "sha256:#{Digest::SHA256.hexdigest(source)}" }
      ))
      FileUtils.mkdir_p(Samagotchi::MemoryPaths.system_dir)
      Samagotchi::MemoryBundle::Installer.new(source: src, name: "contract", scope: "system", strict: true).run
      Thread.current[:contract_generations] = nil
    end

    after { Thread.current[:contract_generations] = nil }

    it "shares its reminder store with the ReminderQueue, fires the hooks and dispatches a plugin's tool" do
      ui = Samagotchi::TerminalUI.new(host_registry: registry, surface: surface, non_interactive: true)
      engine = ui.engine
      session = session_for("box:Qwen3.6")
      server.enqueue("/completion", sse: sse(qwen_call("register_reminder", name: "tea", description: "brew it", interval_minutes: 5)))
      server.enqueue("/completion", sse: sse(qwen_call("contract_echo", text: "hi")))
      server.enqueue("/completion", sse: sse("first done"))
      server.enqueue("/completion", sse: sse("second done"))

      engine.run_turn(session, "remind me")
      store = engine.reminder_store
      store.instance_variable_get(:@mutex).synchronize { store.reminders["tea"][:next_fire_at] = 0.0 }
      engine.run_turn(session, "again")

      expect(store.reminders.keys).to eq(["tea"])
      expect(completions[2].json["prompt"]).to include("[contract_echo]\necho: hi")
      expect(completions[3].json["prompt"]).to include("[SYSTEM: REMINDERS DUE]\n  tea: brew it (interval: 5m)")
      expect(Thread.current[:contract_generations]).to eq([1, 2, 3, 1])
    ensure
      engine&.shutdown
    end
  end
end
