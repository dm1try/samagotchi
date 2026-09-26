# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/session_commands"
require "samagotchi/turn_flow"
require "samagotchi/llm/chat_loop"
require "samagotchi/memory_bundle/installer"
require "samagotchi/log_line"

RSpec.describe "The sample-plugin bundle (Plugin::Api and Plugin::Context)" do
  let(:fixture) { File.expand_path("../../fixtures/sample_plugin_bundle", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("sample-plugin-") }
  let(:system_dir) { File.join(tmpdir, "mem") }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }
  let(:state_home) { File.join(tmpdir, "state") }
  let(:client) { instance_double(Samagotchi::Client, complete: nil) }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["XDG_STATE_HOME"] = state_home
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  before do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = bundles_dir
    Samagotchi::MemoryBundle::Installer.system_dir_override = system_dir
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = File.join(tmpdir, "proj")
    FileUtils.mkdir_p(system_dir)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
  end

  after do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    Samagotchi::MemoryBundle::Installer.system_dir_override = nil
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.system_dir_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.project_dir_base_override = nil
    FileUtils.rm_rf(tmpdir)
  end

  def install(source = fixture, name: "sample-plugin")
    installer = Samagotchi::MemoryBundle::Installer.new(source: source, name: name, scope: "system", strict: true)
    installer.run
    installer
  end

  # A bundle +name+ whose plugin.rb is +source+.
  def install_source(name, source)
    src = File.join(tmpdir, "src-#{name}")
    FileUtils.mkdir_p(src)
    File.write(File.join(src, "plugin.rb"), source)
    manifest = { "name" => name, "version" => "1.0.0", "files" => {},
                 "plugin" => { "file" => "plugin.rb", "sha256" => "sha256:#{Digest::SHA256.hexdigest(source)}" } }
    File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))
    install(src, name: name)
  end

  let(:engine) { Samagotchi::Engine.new(mode: :assist, client: client) }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
      s.messages = [{ role: "user", content: "hi" }, { role: "model", content: "hello" }]
    end
  end
  let(:tools) { engine.instance_variable_get(:@tools) }
  let(:kernel) { engine.instance_variable_get(:@kernel) }

  it "installs cleanly (the fixture's recorded sha256 is its file's)" do
    expect(install.warnings).to be_empty
  end

  describe "chi.command" do
    before { install }

    it "registers /hello in the Engine's registry, from the bundle, and SessionCommands runs it" do
      engine.session = session
      entry = engine.command_registry.lookup("/hello")
      expect(entry.source).to eq("sample-plugin")
      expect(entry.description).to eq("greet, and say what the plugin sees")
      commands = Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                                 default_model: "Gemma-4B-it", registry: engine.command_registry)
      result = commands.run("/hello  Dmitry ")
      expect(result.status).to eq(:ok)
      expect(result.output).to eq("hello, Dmitry (session #{session.id}, 2 messages)")
      expect(commands.run("/hello").output).to start_with("hello, there")
      expect(engine.command_registry.completions(:repl)).to include("/hello")
    end

    it "shows a card with one action; each /hello updates it (the same id)" do
      engine.session = session
      cards = []
      engine.subscribe(observer: ->(e) { cards << e if e[:type] == :card })
      commands = Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                                 default_model: "Gemma-4B-it", registry: engine.command_registry)
      commands.run("/hello")
      commands.run("/hello again")

      expect(cards.map { |c| [c[:id], c[:source], c[:title]] })
        .to eq([["hello", "sample-plugin", "hello, there"], ["hello", "sample-plugin", "hello, again"]])
      expect(cards.last[:body]).to include("**2** messages", "said hello 2 times")
      expect(cards.last[:actions]).to eq([{ label: "Again", command: "/hello again" }])
      expect(cards.last[:in_turn]).to be false
    end

    it "adds /hello-slow as an anytime command, which shows a card after 2 s and prints nothing" do
      engine.session = session
      entry = engine.command_registry.lookup("/hello-slow now")
      expect([entry.name, entry.anytime, entry.source]).to eq(["/hello-slow", true, "sample-plugin"])
      cards = []
      engine.subscribe(observer: ->(e) { cards << e if e[:type] == :card })
      allow_any_instance_of(Object).to receive(:sleep).with(2)
      commands = Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                                 default_model: "Gemma-4B-it", registry: engine.command_registry)

      expect(commands.run("/hello-slow now").output).to be_nil
      expect(cards.map { |c| [c[:title], c[:body]] }).to eq([["slow hello, now", "Ran beside the turn; it saw 2 messages."]])
    end

    it "gets the bundle's settings" do
      allow_any_instance_of(Samagotchi::Engine).to receive(:bundle_settings).and_return("sample-plugin" => { "greeting" => "hey" })
      commands = Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                                 default_model: "Gemma-4B-it", registry: engine.command_registry)
      expect(commands.run("/hello").output).to eq("hey, there (session none, 0 messages)")
    end
  end

  describe "chi.tool" do
    before { install }

    it "adds echo_args and save_note after the built-ins, with its schema" do
      expect(tools.names.last(2)).to eq(%w[echo_args save_note])
      expect(tools["echo_args"].source).to eq("sample-plugin")
      expect(tools["echo_args"].schema).to eq(
        name: "echo_args", description: "Echo the arguments back. A test tool from the sample-plugin bundle.",
        parameters: { type: "object",
                      properties: { text: { type: "string", description: "Any text to echo" },
                                    times: { type: "integer", description: "How many times (optional)" },
                                    loud: { type: "boolean", description: "Shout it (optional)" } },
                      required: ["text"] }
      )
    end

    it "declares save_note's nested schema flat in the native prompts and whole on the chat path" do
      allow(engine).to receive(:profile).and_return(Samagotchi::ModelProfile.qwen36)
      expect(engine.assist_system_prompt).to include('"description": "How the note is written. One of: \\"plain\\", \\"markdown\\"."')
      expect(engine.assist_system_prompt).not_to include("additionalProperties")
      chat = Samagotchi::LLM::ChatLoop.new(kernel: kernel)
      meta = chat.tool_definitions.last[:function][:parameters][:properties][:meta]
      expect(meta).to include(additionalProperties: false, properties: { tags: { type: "array", items: { type: "string" } },
                                                                          priority: { type: "integer" } })
    end

    it "saves a note, its meta typed from a Qwen call's JSON text" do
      Dir.mktmpdir do |dir|
        text = "<tool_call>\n<function=save_note>\n<parameter=path>\n#{dir}/n.md\n</parameter>\n" \
               "<parameter=text>\nhi\n</parameter>\n<parameter=meta>\n{\"tags\": [\"a\"], \"priority\": \"2\"}\n</parameter>\n" \
               "</function>\n</tool_call>"
        call = Samagotchi::ToolCallParser.for_profile(Samagotchi::ModelProfile.qwen36).parse(text).first
        result = kernel.dispatch_tool_call(call)
        expect(result[:output]).to eq("[save_note]\nsaved #{dir}/n.md (priority 2, Integer)")
        expect(result[:activity]).to include(action: "saving note", params: "#{dir}/n.md (2 chars)")
        expect(File.read("#{dir}/n.md")).to eq("tags: a\npriority: 2\nhi\n")
      end
    end

    it "is declared in the native prompt and the chat path's tools, but not in system_prompt_for's" do
      expect(engine.assist_system_prompt).to include("declaration:echo_args{")
      chat = Samagotchi::LLM::ChatLoop.new(kernel: kernel)
      expect(chat.tool_definitions.map { |t| t[:function][:name] }).to include("echo_args")
      expect(Samagotchi::Engine.system_prompt_for(:gemma4)).not_to include("echo_args")
    end

    it "runs through the kernel's dispatch with the parsed args, labelled for the activity line" do
      result = kernel.dispatch_tool_call(name: "echo_args", content: "hi there", args: { "text" => "hi there" })
      expect(result[:output]).to eq("[echo_args]\necho: text=hi there")
      expect(result[:activity][:action]).to eq("echoing")
      expect(result[:activity][:params]).to eq('text="hi there"')
    end

    describe "typed args from each parser" do
      def echo(call) = kernel.dispatch_tool_call(call)[:output]

      it "Gemma: the native call's values, typed by the schema" do
        text = '<|tool_call>call:echo_args{text:<|"|>BANANA42<|"|>,times:3,loud:true}<tool_call|>'
        call = Samagotchi::ToolCallParser.for_profile(Samagotchi::ModelProfile.gemma4).parse(text).first
        expect(echo(call)).to eq("[echo_args]\necho: text=BANANA42 times=3 (Integer) loud=true (TrueClass)")
      end

      it "Qwen: <parameter=…> text, typed by the schema" do
        text = "<tool_call>\n<function=echo_args>\n<parameter=text>\nBANANA42\n</parameter>\n" \
               "<parameter=times>\n3\n</parameter>\n<parameter=loud>\nfalse\n</parameter>\n</function>\n</tool_call>"
        call = Samagotchi::ToolCallParser.for_profile(Samagotchi::ModelProfile.qwen36).parse(text).first
        expect(echo(call)).to eq("[echo_args]\necho: text=BANANA42 times=3 (Integer) loud=false (FalseClass)")
      end

      it "chat: the JSON arguments, a number given as text typed too" do
        ref = Struct.new(:name, :arguments).new("echo_args", '{"text":"BANANA42","times":"3"}')
        call = Samagotchi::LLM::NativeToolNormalizer.normalize(ref)
        expect(echo(call)).to eq("[echo_args]\necho: text=BANANA42 times=3 (Integer)")
      end
    end

    it "shows a card when it runs" do
      cards = []
      engine.subscribe(observer: ->(e) { cards << e if e[:type] == :card })
      kernel.dispatch_tool_call(name: "echo_args", text: "hi")
      expect(cards.map { |c| [c[:title], c[:body]] }).to eq([["echo_args ran", "echo: text=hi"]])
    end
  end

  describe "chi.on" do
    before { install }

    it "runs the after_turn hook with the Context: data_dir is created on first use" do
      engine.session = session
      data_dir = File.join(state_home, "samagotchi", "plugins", "sample-plugin")
      expect(Dir.exist?(data_dir)).to be false
      engine.instance_variable_get(:@hooks).fire(:after_turn, { type: :after_turn })
      expect(File.read(File.join(data_dir, "turns.log"))).to eq("#{session.id}\n")
    end
  end

  describe "name clashes" do
    it "is a load error for a built-in command or tool, and the plugin adds nothing" do
      install_source("clash", <<~RUBY)
        class Plugin
          def register(chi)
            chi.tool("fine_tool", "ok") { "" }
            chi.command("/model", "mine") { "" }
          end
        end
      RUBY
      eng = nil
      expect { eng = Samagotchi::Engine.new(mode: :assist, client: client) }
        .to output(%r{command /model is already registered \(core\)}).to_stderr
      expect(eng.instance_variable_get(:@tools).key?("fine_tool")).to be false
      expect(eng.plugin_failures.list.map(&:what)).to eq(["plugin plugin.rb (bundle clash)"])

      install_source("clash", "class Plugin; def register(chi) = chi.tool(\"read\", \"mine\") { \"\" }; end\n")
      expect { Samagotchi::Engine.new(mode: :assist, client: client) }.to output(/tool read is already registered \(core\)/).to_stderr
    end

    it "is a load error for the second bundle that takes a name" do
      install
      install_source("again", "class Plugin; def register(chi) = chi.command(\"/hello\", \"mine\") { \"\" }; end\n")
      expect { engine }.to output(%r{bundle 'sample-plugin' plugin 'plugin.rb' not loaded: .*command /hello is already registered \(again\)}).to_stderr
    end

    it "refuses names that aren't plain" do
      install_source("names", "class Plugin; def register(chi) = chi.tool(\"Bad-Name\", \"x\") { \"\" }; end\n")
      expect { engine }.to output(/tool name "Bad-Name" must be a-z/).to_stderr
    end
  end

  describe Samagotchi::Plugin::Context do
    let(:notices) { [] }
    let(:host) do
      Samagotchi::Plugin::Host.new(
        session_id: -> { "sid-1" }, cwd: -> { tmpdir }, messages: -> { [{ role: "user", content: "hi" }] },
        notify: ->(text, level, label) { notices << [text, level, label] },
        ask_user: ->(**kw) { { selected: [kw[:options].first], hook: kw[:hook] } },
        cancelled: -> { nil }
      )
    end
    let(:ctx) do
      described_class.new(bundle: "b", label: "plugin.rb (bundle b)", settings: { "k" => { "n" => "v" } }, host: host)
    end

    it "reads the session through the host" do
      expect(ctx.session_id).to eq("sid-1")
      expect(ctx.cwd).to eq(tmpdir)
      expect(ctx.cancelled?).to be false
    end

    it "hands out frozen copies of the messages and settings" do
      expect(ctx.messages).to be_frozen
      expect(ctx.messages.first).to be_frozen
      expect(ctx.settings).to be_frozen
      expect(ctx.settings["k"]).to be_frozen
    end

    it "labels notices and questions by the plugin" do
      ctx.notify("hi", level: :warn)
      expect(notices).to eq([["hi", :warn, "plugin.rb (bundle b)"]])
      expect(ctx.ask_user(question: "q", options: %w[a b])).to eq(selected: ["a"], hook: "plugin.rb (bundle b)")
    end

    it "writes debug-log records tagged plugins, with the bundle" do
      file = File.join(tmpdir, "chi.log")
      Samagotchi::Log.configure(path: file, level: :debug, stderr: false)
      ctx.log.info(:did, n: 1)
      record = Samagotchi::LogLine.parse(File.read(file).lines.last.chomp)
      expect([record.level, record.tag, record.event]).to eq(%w[INFO plugins did])
      expect(record.fields).to eq("bundle" => "b", "n" => "1")
    ensure
      Samagotchi::Log.reset!
    end

    it "finds the git checkout of cwd" do
      checkout = File.expand_path("../../..", __dir__)
      ctx = described_class.new(bundle: "b", label: "l", settings: {},
                                host: Samagotchi::Plugin::Host.new(cwd: -> { File.join(checkout, "lib") }))
      expect(File.realpath(ctx.repo_root)).to eq(File.realpath(checkout))
    end
  end
end
