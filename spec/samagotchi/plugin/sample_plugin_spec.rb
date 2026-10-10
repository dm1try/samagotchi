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
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }
  let(:state_home) { File.join(tmpdir, "state") }
  let(:client) { instance_double(Samagotchi::Client, complete: nil) }
  let(:engine) { Samagotchi::Engine.new(client: client) }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
      s.messages = [{ role: "user", content: "hi" }, { role: "model", content: "hello" }]
    end
  end
  let(:tools) { engine.instance_variable_get(:@tools) }
  let(:kernel) { engine.instance_variable_get(:@kernel) }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["XDG_STATE_HOME"] = state_home
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  before do
    FileUtils.mkdir_p(system_dir)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
  end

  after do
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
      result = commands.run("/hello  Jordan ")
      expect(result.status).to eq(:ok)
      expect(result.output).to eq("hello, Jordan (session #{session.id}, 2 messages)")
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
      allow_any_instance_of(Samagotchi::ExtensionLoad).to receive(:bundle_settings).and_return("sample-plugin" => { "greeting" => "hey" })
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

    it "tells guardrail path rules the file save_note writes" do
      rule = Samagotchi::Guardrails::Rules.parse([{ "id" => "no-secrets", "path" => "**/secret*", "verdict" => "deny",
                                                    "reason" => "secrets stay put" }], source: "config")
      allow(engine.instance_variable_get(:@guardrail_wiring)).to receive(:rules).and_return(Samagotchi::Guardrails::Rules.new(rule))
      run = lambda do |call|
        Samagotchi::ToolRunner.new(kernel).run(call, iteration: 1, call_index: 1, call_count: 1,
                                                     on_stream_event: nil, max_tool_output_chars: nil)
      end
      Dir.mktmpdir do |dir|
        denied = run.call(name: "save_note", args: { "path" => "#{dir}/secret.md", "text" => "x" })
        expect(denied[:output]).to include("no-secrets").and include("secrets stay put")
        expect(File.exist?("#{dir}/secret.md")).to be false
        allowed = run.call(name: "save_note", args: { "path" => "#{dir}/plain.md", "text" => "x" })
        expect(allowed[:output]).to eq("[save_note]\nsaved #{dir}/plain.md")
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

  describe "returning images (Plugin::ToolResult)" do
    let(:png_path) { File.expand_path("../../fixtures/images/tiny.png", __dir__) }
    let(:session_dir) { File.join(tmpdir, "session") }

    before do
      install_source("shots", <<~RUBY)
        class Plugin
          def register(chi)
            chi.tool("shoot", "take shots", params: { path: { type: "string" } }) do |args, _ctx|
              Samagotchi::Plugin::ToolResult.new("took 2 shots",
                images: [{ path: args["path"] }, { bytes: File.binread(args["path"]), name: "frame.png" }, { oops: true }])
            end
            chi.tool("plain", "text only") { 42 }
          end
        end
      RUBY
      FileUtils.mkdir_p(session_dir)
    end

    def run(call)
      Samagotchi::ToolRunner.new(kernel).run(call, iteration: 1, call_index: 1, call_count: 1,
                                                   on_stream_event: nil, max_tool_output_chars: nil)
    end

    it "attaches the images, and a bad entry is an Error: line for that image only" do
      vision = Samagotchi::VisionContext.new(session_dir: session_dir, resizer: Samagotchi::ImageResizer.new(nil))
      kernel.turn_settings = kernel.turn_settings.with(vision: vision)
      result = run(name: "shoot", args: { "path" => png_path })
      expect(result[:output]).to eq("[shoot]\ntook 2 shots\nError: image 3 is not {path:} or {bytes:, name:}")
      expect(result[:images].map { |ref| ref[:name] }).to eq(%w[tiny.png frame.png])
    end

    it "keeps the text when the model can't see images" do
      blind = Samagotchi::VisionContext.new(session_dir: session_dir,
                                            capability: Samagotchi::VisionSupport::Answer.new(value: false, reason: "no"))
      kernel.turn_settings = kernel.turn_settings.with(vision: blind)
      result = run(name: "shoot", args: { "path" => png_path })
      expect(result[:output]).to start_with("[shoot]\ntook 2 shots\ntiny.png is an image; this model can't see images\n")
      expect(result).not_to have_key(:images)
    end

    it "leaves a block that returns something else as its text" do
      expect(run(name: "plain", args: {})[:output]).to eq("[plain]\n42")
    end
  end

  describe "chi.tools_changed!" do
    it "drops the built system prompts, so the next turn declares the tools again" do
      install_source("late-tools", <<~RUBY)
        class Plugin
          def register(chi)
            @chi = chi
            chi.command("/changed", "say the tools changed") { @chi.tools_changed! }
          end
        end
      RUBY
      commands = Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                                 default_model: "Gemma-4B-it", registry: engine.command_registry)
      built = engine.system_prompt
      expect(engine.system_prompt).to equal(built)
      commands.run("/changed")
      expect(engine.system_prompt).not_to equal(built)
      expect(engine.system_prompt).to eq(built)
    end
  end

  describe "chi.replace_tools" do
    # A plugin whose /set command replaces its tools with the names given.
    before do
      install_source("late-tools", <<~RUBY)
        class Plugin
          def register(chi)
            @chi = chi
            chi.tool("late_a", "first") { "a" }
            chi.command("/set", "replace the tools") do |args|
              @chi.replace_tools do |set|
                args.split.each do |name|
                  set.tool(name, name == "late_a" ? "first" : "changed \#{name}", label: name) { |_a, ctx| "\#{name} in \#{ctx.bundle}" }
                end
              end
              nil
            end
            chi.command("/early", "") { nil }
          end
        end
      RUBY
    end

    let(:commands) do
      Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                      default_model: "Gemma-4B-it", registry: engine.command_registry)
    end

    def late_names = tools.entries.select { |e| e.source == "late-tools" }.map(&:name)

    it "stages the set; the turn thread applies it: new tools, dropped ones, the prompts built again once" do
      built = engine.system_prompt
      commands.run("/set late_b late_c")
      # Staged only: nothing changes until it is applied.
      expect(late_names).to eq(%w[late_a])
      expect(engine.system_prompt).to equal(built)
      expect(engine.apply_staged_tools!).to be(true)
      expect(late_names).to eq(%w[late_b late_c])
      expect(tools["late_b"].label).to eq("late_b")
      expect(tools["late_b"].handler.call({ name: "late_b", args: {} }, nil)).to eq("late_b in late-tools")
      expect(engine.system_prompt).not_to equal(built)
      expect(engine.system_prompt).to include("late_c")
      expect(engine.apply_staged_tools!).to be(false)
    end

    it "keeps an unchanged tool as it is, and changes nothing for the same set" do
      commands.run("/set late_a")
      # The declared label differs from the load's (nil): a change.
      expect(engine.apply_staged_tools!).to be(true)
      entry = tools["late_a"]
      commands.run("/set late_a")
      expect(engine.apply_staged_tools!).to be(false)
      expect(tools["late_a"]).to equal(entry)
    end

    it "leaves out a name another source has, with a notice" do
      notices = []
      engine.subscribe(observer: ->(e) { notices << e if e[:type] == :hook_notice })
      commands.run("/set read late_b")
      engine.apply_staged_tools!
      expect(tools["read"].source).to eq("core")
      expect(late_names).to eq(%w[late_b])
      expect(notices.map { |n| n[:text] }).to eq(["tool read is already registered (core); left out"])
    end

    it "is refused inside register, and a bad tool raises at once, staging nothing" do
      install_source("early", <<~RUBY)
        class Plugin
          def register(chi) = chi.replace_tools { |set| set.tool("x", "") { "" } }
        end
      RUBY
      expect(engine.plugin_failures.message).to include("replace_tools is for after register")
      expect(commands.run("/set BAD").output).to include("tool name \"BAD\" must be a-z")
      expect(engine.apply_staged_tools!).to be(false)
      expect(late_names).to eq(%w[late_a])
    end
  end

  describe "chi.init" do
    it "adds a task that runs only when started, with the Context; a bad one is a load error" do
      install_source("slow-setup", <<~RUBY)
        class Plugin
          def register(chi)
            chi.init("Indexing the repo", provides_tools: true, timeout: 7) { |ctx| "indexed for \#{ctx.bundle}" }
          end
        end
      RUBY
      install_source("bad-init", <<~RUBY)
        class Plugin
          def register(chi) = chi.init(" ") { nil }
        end
      RUBY
      finished = []
      engine.subscribe(observer: ->(e) { finished << e if e[:type] == :plugin_init_finished })
      task = engine.instance_variable_get(:@plugin_tasks).tasks.first
      expect(task.to_h.slice(:bundle, :label, :provides_tools, :quiet, :timeout, :state))
        .to eq(bundle: "slow-setup", label: "Indexing the repo", provides_tools: true, quiet: false, timeout: 7.0, state: :pending)
      expect(engine.plugin_failures.message).to include("init needs a label")
      engine.start_init_tasks!
      task.thread.join(2)
      expect(finished.map { |e| e[:summary] }).to eq(["indexed for slow-setup"])
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
      expect { eng = Samagotchi::Engine.new(client: client) }
        .to output(%r{command /model is already registered \(core\)}).to_stderr
      expect(eng.instance_variable_get(:@tools).key?("fine_tool")).to be false
      expect(eng.plugin_failures.list.map(&:what)).to eq(["plugin plugin.rb (bundle clash)"])

      install_source("clash", "class Plugin; def register(chi) = chi.tool(\"read\", \"mine\") { \"\" }; end\n")
      expect { Samagotchi::Engine.new(client: client) }.to output(/tool read is already registered \(core\)/).to_stderr
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
        notify: ->(text, level, label, fallback_for:) { notices << [text, level, label, fallback_for] },
        ask_user: ->(**kw) { { selected: [kw[:options].first], hook: kw[:hook] } },
        cancelled: -> {}
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
      ctx.notify("sources: a", fallback_for: :display)
      expect(notices).to eq([["hi", :warn, "plugin.rb (bundle b)", nil], ["sources: a", :info, "plugin.rb (bundle b)", :display]])
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
