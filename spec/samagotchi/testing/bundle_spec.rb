# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "samagotchi/testing"

# Samagotchi::Testing::Bundle: a bundle loaded through chi's own loaders,
# fired and called through its registries, with the edges recorded.
RSpec.describe Samagotchi::Testing::Bundle do
  let(:dir) { Dir.mktmpdir("kit-bundle-") }
  let(:loaded) { [] }
  let(:plugin) do
    <<~RUBY
      class Plugin
        VERSION_SEEN = Samagotchi::VERSION

        def initialize(settings) = @word = settings.fetch("word", "hi")

        def register(chi)
          chi.command("/say", "says the word") { |args, ctx| ctx.notify("\#{@word} \#{args}"); "said" }
          chi.tool("shout", "shouts", params: { text: { type: "string", required: true }, times: { type: "integer" } }) do |args, _ctx|
            ([args["text"].upcase] * (args["times"] || 1)).join(" ")
          end
          chi.on(:after_turn) { |event, ctx| ctx.card(title: "done", body: event[:status].to_s) }
          chi.on(:before_turn) { |event, ctx| event[:steered] = ctx.steer("go on") }
          chi.on(:generation_progress) do |event, ctx|
            raise "broken stream hook" if event[:text] == "boom"

            ctx.stop_generation("cut") if event[:text] == "cut"
            ctx.stop_turn("stop") if event[:text] == "stop"
          end
          chi.init("warming up") { |ctx| "ready in \#{ctx.cwd}" }
        end
      end
    RUBY
  end

  after do
    loaded.each(&:shutdown)
    FileUtils.rm_rf(dir)
  end

  # A bundle in +dir+: plugin.rb (when given) and hooks/<file> => [event, source].
  def write_bundle(plugin: nil, hooks: {}, name: "kit-test")
    manifest = { "name" => name, "version" => "1.0.0", "files" => {} }
    if plugin
      File.write(File.join(dir, "plugin.rb"), plugin)
      manifest["plugin"] = { "file" => "plugin.rb", "sha256" => "" }
    end
    unless hooks.empty?
      FileUtils.mkdir_p(File.join(dir, "hooks"))
      manifest["hooks"] = hooks.to_h do |file, (event, source, on_error)|
        File.write(File.join(dir, "hooks", file), source)
        [file, { "event" => event, "on_error" => on_error || "skip" }]
      end
    end
    File.write(File.join(dir, "manifest.yml"), YAML.dump(manifest))
    dir
  end

  def load(**) = described_class.load(dir, **).tap { |bundle| loaded << bundle }

  it "loads the plugin and its hook files through chi's loaders, with chi's built-ins registered beside them" do
    write_bundle(plugin: plugin, hooks: { "guard.rb" => ["before_tool_call", "class Guard; def call(e) = nil; end"] })
    bundle = load(settings: { word: "hey" })

    expect(bundle.name).to eq("kit-test")
    expect(bundle.api.counts).to include(commands: 1, tools: 1, hooks: 3, inits: 1)
    expect(bundle.bundle_commands.map(&:name)).to eq(["/say"])
    expect(bundle.bundle_tools.map(&:name)).to eq(["shout"])
    expect(bundle.commands.lookup("/model").source).to eq("core")
    expect(bundle.tools["execute"]).not_to be_nil
    expect(bundle.hook_names(:before_tool_call)).to eq([["kit-test", "guard.rb", 100]])
    expect(bundle.hook_names(:after_turn)).to eq([["kit-test", "plugin.rb", 100]])
    expect(bundle.namespace::Plugin::VERSION_SEEN).to eq(Samagotchi::VERSION)
    expect(bundle.hooks_namespace::Guard).to be_a(Class)
    expect(bundle.ctx).to be_a(Samagotchi::Plugin::Context)
    expect(bundle.ctx.settings).to eq("word" => "hey")
  end

  describe "session_settings (a session's --set values)" do
    let(:settings_plugin) do
      <<~RUBY
        class Plugin
          def initialize(settings) = @at_load = settings

          def register(chi)
            chi.command("/seen", "what it sees") { |_args, ctx| [@at_load, ctx.settings] }
          end
        end
      RUBY
    end

    def write_settings_bundle(session_settings: %w[cap])
      write_bundle(plugin: settings_plugin)
      path = File.join(dir, "manifest.yml")
      File.write(path, YAML.dump(YAML.load_file(path).merge("session_settings" => session_settings)))
    end

    it "lays them over the config in ctx.settings; the plugin's initialize sees the config only" do
      write_settings_bundle
      bundle = load(settings: { cap: 5, warn_at: 0.5 }, session_settings: { cap: 0.25 })

      at_load, seen = bundle.command("/seen")
      expect(at_load).to eq("cap" => 5, "warn_at" => 0.5)
      expect(seen).to eq("cap" => 0.25, "warn_at" => 0.5)
      expect(seen).to be_frozen
      expect(bundle.recorder[:setup].bundle_settings).to eq("kit-test" => { "cap" => 0.25 })
    end

    it "changes them mid-test with set(session_settings:), on a new session id so the per-session cache is rebuilt" do
      write_settings_bundle
      bundle = load(settings: { cap: 5 })
      expect(bundle.command("/seen").last).to eq("cap" => 5)

      bundle.set(session_settings: { cap: 1 })
      expect(bundle.command("/seen").last).to eq("cap" => 1)
      expect(bundle.ctx.session_id).to eq("test-session-2")

      bundle.set(session_settings: { cap: 2 }, session_id: "other")
      expect(bundle.command("/seen").last).to eq("cap" => 2)
      expect(bundle.ctx.session_id).to eq("other")
    end

    it "gives the config only before the session is bound (no session id yet)" do
      write_settings_bundle
      bundle = load(settings: { cap: 5 }, session_settings: { cap: 1 }, host: { session_id: nil })
      expect(bundle.command("/seen").last).to eq("cap" => 5)

      bundle.set(session_id: "bound")
      expect(bundle.command("/seen").last).to eq("cap" => 1)
    end

    it "refuses a key the manifest doesn't list in session_settings:, as chi --set does" do
      write_settings_bundle(session_settings: %w[cap])
      expect { load(session_settings: { default: 1 }) }.to raise_error(ArgumentError, "session_settings kit-test.default: kit-test takes cap")
      write_settings_bundle(session_settings: [])
      expect { load(session_settings: { cap: 1 }) }.to raise_error(ArgumentError, /kit-test takes no session settings/)
    end
  end

  it "keeps hook classes isolated between loads without adding constants to the shared namespace" do
    write_bundle(hooks: { "guard.rb" => ["after_turn", "class Guard; def call(e) = e[:first] = true; end"] })
    shared_namespace = Samagotchi::Hooks::BundleLoader.namespace_for("kit-test")
    constants_before = shared_namespace.constants(false)
    first = load
    File.write(File.join(dir, "hooks", "guard.rb"), "class Guard; def call(e) = e[:second] = true; end\n")
    second = load

    expect(first.hooks_namespace).not_to equal(second.hooks_namespace)
    expect(first.fire(:after_turn)[:first]).to be(true)
    expect(first.fire(:after_turn)).not_to have_key(:second)
    expect(second.fire(:after_turn)[:second]).to be(true)
    expect(second.fire(:after_turn)).not_to have_key(:first)
    expect(shared_namespace.constants(false)).to eq(constants_before)
  end

  it "fails to load a plugin whose command clashes with chi's own, as chi would" do
    write_bundle(plugin: "class Plugin; def register(chi) = chi.command('/model', 'x') { nil }; end")
    expect { load }.to raise_error(ArgumentError, "command /model is already registered (core)")
  end

  it "runs a command with the text after its name, and records what the ctx helpers did" do
    write_bundle(plugin: plugin)
    bundle = load
    expect(bundle.command("/say  there ")).to eq("said")
    expect(bundle.notices.map(&:to_h)).to eq([{ text: "hi there", level: :info, hook: "plugin.rb (bundle kit-test)", fallback_for: nil }])
    expect { bundle.command("/model") }.to raise_error(ArgumentError, /chi's own command/)
  end

  it "calls a tool with its args typed by the schema, returning the text the model reads" do
    write_bundle(plugin: plugin)
    expect(load.tool("shout", text: "a", times: "2")).to eq("A A")
  end

  it "fires an event with its type and the runtime helpers, through the plugin's real Context" do
    write_bundle(plugin: plugin)
    bundle = load
    event = bundle.fire(:before_turn, prompt: "x")
    expect(event).to include(type: :before_turn, prompt: "x", steered: true)
    expect(bundle.steers.map(&:to_h)).to eq([{ text: "go on", hook: "plugin.rb (bundle kit-test)" }])

    bundle.set(running: false)
    expect(bundle.fire(:before_turn)[:steered]).to be false

    bundle.fire(:after_turn, status: "completed")
    card = bundle.cards.last
    expect(card).to include(type: :card, source: "kit-test", title: "done", body: "completed", level: :info, actions: [])
    expect(card[:id]).to match(/\A\h{8}\z/)
  end

  describe "bundle.set(cost:), what ctx.cost reads" do
    let(:spend) do
      <<~RUBY
        class Plugin
          def initialize(_settings); end

          def register(chi)
            chi.command("/spend", "shows ctx.cost") do |_args, ctx|
              cost = ctx.cost
              [cost.total, cost.reported, cost.estimated, cost.side, cost.known?]
            end
          end
        end
      RUBY
    end

    before { write_bundle(plugin: spend) }

    it "is zero and known when the test sets none" do
      expect(load.command("/spend")).to eq([0.0, 0.0, 0.0, 0.0, true])
    end

    it "takes a number (reported USD) or a hash of the parts" do
      bundle = load
      expect(bundle.set(cost: 2.5).command("/spend")).to eq([2.5, 2.5, 0.0, 0.0, true])

      bundle.set(cost: { reported: 2.0, estimated: 0.5, side: 0.1, known: true })
      expect(bundle.command("/spend")).to eq([2.5, 2.0, 0.5, 0.1, true])
      expect(bundle.set(cost: { known: false }).command("/spend")).to eq([0.0, 0.0, 0.0, 0.0, false])
    end

    it "takes a callable, called at each read" do
      reads = 0
      bundle = load(host: { cost: -> { reads += 1 } })
      expect(bundle.command("/spend").first).to eq(1.0)
      expect(bundle.command("/spend").first).to eq(2.0)
      expect(reads).to eq(2)
    end

    it "refuses an unknown part" do
      bundle = load(host: { cost: { spent: 1 } })
      expect { bundle.command("/spend") }.to raise_error(ArgumentError, /spent/)
    end
  end

  it "builds a before_tool_call event with the fields the real gate dispatches" do
    write_bundle
    bundle = load(host: { cwd: "/work" })
    call = { name: "read", path: "notes.md" }
    context = Samagotchi::Guardrails::Context.new(cwd: "/work", session_id: "test-session",
                                                  interface: :non_interactive)
    verdict = Samagotchi::Testing::Verdict.new(call: call)
    event = bundle.before_tool_call_event(call, iteration: 2, params: "read notes.md",
                                                context: context, verdict: verdict)

    dispatched = nil
    hooks = Samagotchi::Hooks::Registry.new
    hooks.register(:before_tool_call) { |payload| dispatched = payload.dup }
    gate = Samagotchi::Guardrails::Gate.new(-> { hooks }, context_lookup: -> { context },
                                                                    tools_lookup: -> { bundle.tools })
    gate.evaluate(call, iteration: 2, params: "read notes.md", verdict: Samagotchi::Testing::Verdict.new(call: call))
    real_event = dispatched.slice(:type, :iteration, :call, :params, :blocked, :block_reason, :guardrail, :context,
                                  :targets)

    expect(event.keys).to eq(real_event.keys)
    expect(event.except(:guardrail)).to eq(real_event.except(:guardrail))
    expect(event[:guardrail]).to be_a(Samagotchi::Testing::Verdict)
  end

  it "explains when the gate doesn't dispatch before_tool_call" do
    write_bundle
    bundle = load
    gate = double(evaluate: nil)
    allow(Samagotchi::Guardrails::Gate).to receive(:new).and_return(gate)

    expect { bundle.before_tool_call_event({ name: "execute" }, params: "execute") }
      .to raise_error(ArgumentError, 'guardrails did not dispatch a before_tool_call event for "execute"')
  end

  it "records stop_turn and stop_generation in one list, in order, and apart" do
    write_bundle(plugin: plugin)
    bundle = load
    %w[cut stop cut].each { |text| bundle.fire(:generation_progress, text: text) }
    expect(bundle.stops.map { |stop| [stop.kind, stop.reason] }).to eq([[:generation, "cut"], [:turn, "stop"], [:generation, "cut"]])
    expect(bundle.turn_stops.map(&:reason)).to eq(["stop"])
    expect(bundle.generation_stops.size).to eq(2)
  end

  it "raises a hook's error after the fire (chi would log it), or collects it under lenient" do
    write_bundle(plugin: plugin, hooks: { "flaky.rb" => ["after_turn", "class Flaky; def call(e) = raise(ArgumentError, 'flaky broke'); end"] })
    bundle = load
    expect { bundle.fire(:generation_progress, text: "boom") }
      .to raise_error(Samagotchi::Testing::HookFailed, /plugin.rb \(bundle kit-test\) generation_progress hook raised on generation_progress: RuntimeError: broken stream hook/)
    expect { bundle.fire(:generation_progress, text: "boom") }.to raise_error(Samagotchi::Testing::HookFailed)
    expect { bundle.fire(:after_turn, status: "x") }.to raise_error(Samagotchi::Testing::HookFailed, /flaky\.rb \(bundle kit-test\).*flaky broke/)
    expect(bundle.cards.size).to eq(1) # the plugin's after_turn hook ran first all the same

    bundle.lenient { bundle.fire(:after_turn, status: "y") }
    expect(bundle.errors.map { |failure| failure.error.message }).to eq(["flaky broke"])
  end

  it "reports every failing hook in one HookFailed error" do
    write_bundle(hooks: {
      "first.rb" => ["after_turn", "class First; def call(e) = raise('first broke'); end"],
      "second.rb" => ["after_turn", "class Second; def call(e) = raise('second broke'); end"]
    })
    bundle = load

    expect { bundle.fire(:after_turn) }.to raise_error(Samagotchi::Testing::HookFailed) { |error|
      expect(error.failures.map(&:hook)).to eq(["first.rb (bundle kit-test)", "second.rb (bundle kit-test)"])
      expect(error.message).to include("first broke", "second broke")
      expect(error.cause.message).to eq("first broke")
    }
  end

  it "evaluates a tool call through a real Gate: the hooks vote on a recording Verdict, with context and targets" do
    guard = <<~RUBY
      class Guard
        def call(event)
          return unless event[:targets][:command].to_s.include?("rm")

          event[:guardrail].deny!("no rm in \#{event[:context][:cwd]}", rule: "no-rm", advice: "use trash")
        end
      end
    RUBY
    write_bundle(hooks: { "guard.rb" => ["before_tool_call", guard] })
    bundle = load(host: { cwd: "/work" })

    verdict = bundle.tool_call({ name: "execute", content: "rm -rf x" })
    expect(verdict).to be_a(Samagotchi::Testing::Verdict)
    expect(verdict).to be_deny
    expect(verdict.votes.map(&:to_h)).to eq([{ decision: :deny, reason: "no rm in /work", options: { rule: "no-rm", advice: "use trash" } }])
    expect(verdict.targets.command).to eq("rm -rf x")
    expect(bundle.tool_call({ name: "execute", content: "ls" })).to be_allow

    earlier = Samagotchi::Testing::Verdict.new(call: {}).deny!("other voter")
    expect(bundle.tool_call({ name: "execute", content: "rm x" }, verdict: earlier).reason).to eq("other voter")
  end

  it "fails the tool call when a fail-closed guardrail raises, which also denies" do
    write_bundle(hooks: { "guard.rb" => ["before_tool_call", "class Guard; def call(e) = raise('oops'); end", "fail_closed"] })
    bundle = load
    expect { bundle.tool_call({ name: "read", path: "x" }) }.to raise_error(Samagotchi::Testing::HookFailed, /guardrail guard\.rb.*oops/)
    verdict = bundle.lenient { bundle.tool_call({ name: "read", path: "x" }) }
    expect(verdict).to be_deny
  end

  it "records init tasks and runs them with the ctx, and stages replace_tools sets until applied" do
    write_bundle(plugin: <<~RUBY)
      class Plugin
        def register(chi)
          @chi = chi
          chi.init("indexing", provides_tools: true, timeout: 5) do |ctx|
            @chi.replace_tools { |set| set.tool("late", "a late tool") { |_args, _ctx| "late!" } }
            "1 tool"
          end
        end
      end
    RUBY
    bundle = load
    expect(bundle.inits.map { |init| [init.label, init.provides_tools, init.timeout] }).to eq([["indexing", true, 5.0]])
    expect(bundle.run_inits).to eq(["1 tool"])
    expect(bundle.staged_tools.size).to eq(1)
    expect(bundle.tools["late"]).to be_nil
    expect(bundle.apply_staged_tools!).to be true
    expect(bundle.tool("late")).to eq("late!")
  end

  it "answers ask_user and ask_model from queues, and records the requests" do
    write_bundle(plugin: <<~RUBY)
      class Plugin
        def register(chi)
          chi.command("/ask", "asks") do |_args, ctx|
            picked = ctx.ask_user(question: "which?", options: %w[a b], effects: { "b" => :spend })
            answer = ctx.ask_model(messages: ctx.messages, prompt: "why \#{picked&.fetch(:selected)}?", timeout: 5)
            "\#{picked&.fetch(:selected)}: \#{answer}"
          end
        end
      end
    RUBY
    bundle = load(host: { messages: [{ role: "user", content: "hello" }] })
    bundle.answer({ selected: "b" })
    bundle.model_answers << "because"
    expect(bundle.command("/ask")).to eq("b: because")
    expect(bundle.questions.map { |q| [q.question, q.options, q.hook] }).to eq([["which?", %w[a b], "plugin.rb (bundle kit-test)"]])
    # The tags as the plugin gave them, for a spec to assert.
    expect(bundle.questions.first.effects).to eq("b" => :spend)
    expect(bundle.model_requests.first.timeout).to eq(5.0)
    expect(bundle.model_requests.first.request.last[:content]).to include("why b?")

    expect { bundle.command("/ask") }.to raise_error(Samagotchi::Plugin::ModelError, /no model answer queued/)
  end

  it "asks no one for effects chi would refuse, as chi does: nil, nothing recorded" do
    write_bundle(plugin: <<~RUBY)
      class Plugin
        def register(chi)
          chi.command("/ask", "asks") do |_args, ctx|
            ctx.ask_user(question: "go on?", options: %w[Continue Stop], effects: { "Contniue" => :spend }).inspect
          end
        end
      end
    RUBY
    bundle = load
    bundle.answer({ selected: ["Continue"] })
    expect(bundle.command("/ask")).to eq("nil")
    expect(bundle.questions).to be_empty
    # The queued answer is still there for the next ask.
    expect(bundle.recorder.answers.size).to eq(1)
  end

  it "gives ctx.sessions the recording Sessions, with scripted answers" do
    write_bundle(plugin: <<~RUBY)
      class Plugin
        def register(chi)
          chi.command("/kids", "lists") { |_args, ctx| ctx.sessions.children(all: true).map { |c| c[:id] }.join(",") }
          chi.command("/poke", "sends") { |args, ctx| ctx.sessions.send(ctx.session_id, args) }
        end
      end
    RUBY
    bundle = load
    bundle.sessions.on(:children) { |all:| all ? [{ id: "c1" }, { id: "c2" }] : [] }
    expect(bundle.command("/kids")).to eq("c1,c2")
    expect(bundle.command("/poke hello")).to eq("test-session")
    expect(bundle.sessions.calls_to(:send).map(&:args)).to eq([%w[test-session hello]])
  end

  it "keeps the plugin's data and the debug log in the sandbox, and reads its config.yml" do
    write_bundle(plugin: "class Plugin; def register(chi) = nil; end")
    Samagotchi::Testing::Sandbox.with do |sandbox|
      sandbox.config("default" => { "model" => "kit-model" })
      bundle = load
      expect(bundle.sandbox).to be(sandbox)
      expect(bundle.ctx.data_dir).to start_with(sandbox.root)
      expect(Samagotchi::Config.get("default.model")).to eq("kit-model")
      expect(ENV["HOME"]).to start_with(sandbox.root)
    end
  end

  it "enters a sandbox of its own when none is current and leaves it at shutdown" do
    write_bundle(plugin: "class Plugin; def register(chi) = nil; end")
    home = ENV.fetch("XDG_STATE_HOME")
    bundle = load
    root = bundle.sandbox.root
    expect(ENV.fetch("XDG_STATE_HOME")).to start_with(root)
    bundle.shutdown
    expect(ENV.fetch("XDG_STATE_HOME")).to eq(home)
    expect(File.exist?(root)).to be false
  end

  it "keeps the plugin's instance and the chi.* calls #register made, in order, as made" do
    write_bundle(plugin: plugin)
    bundle = load
    expect(bundle.plugin).to be_a(bundle.namespace::Plugin)
    expect(bundle.declarations.map(&:name)).to eq(%i[command tool on on on init])
    tool = bundle.declarations[1]
    expect(tool.args).to eq(%w[shout shouts])
    expect(tool.options[:params]).to eq(text: { type: "string", required: true }, times: { type: "integer" })
  end

  it "loads a shipped bundle by name" do
    bundle = described_class.shipped("check-in").tap { |b| loaded << b }
    expect(bundle.bundle_commands.map(&:name)).to eq(["/checkin"])
  end
end
