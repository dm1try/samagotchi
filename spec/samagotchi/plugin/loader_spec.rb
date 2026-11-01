# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"
require "samagotchi/engine"
require "samagotchi/terminal_ui/event_renderer"
require "samagotchi/memory_bundle/installer"

RSpec.describe Samagotchi::Plugin::Loader do
  let(:tmpdir) { Dir.mktmpdir("plugin-loader-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }
  let(:client) { instance_double(Samagotchi::Client, complete: nil) }
  let(:hook_plugin) do
    <<~RUBY
      class Plugin
        def initialize(settings)
          @mark = settings.fetch("mark", "hit")
        end

        def register(chi)
          chi.on(:before_turn) { |event| event[:marks] = Array(event[:marks]) + [@mark, event[:hook]] }
        end
      end
    RUBY
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

  # Install a bundle +name+ whose plugin.rb is +source+.
  def install_plugin(name, source, requires_chi: nil)
    src = File.join(tmpdir, "src-#{name}")
    FileUtils.mkdir_p(src)
    File.write(File.join(src, "plugin.rb"), source)
    manifest = { "name" => name, "version" => "1.0.0", "files" => {},
                 "plugin" => { "file" => "plugin.rb", "sha256" => "sha256:#{Digest::SHA256.hexdigest(source)}" } }
    manifest["requires_chi"] = requires_chi if requires_chi
    File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))
    Samagotchi::MemoryBundle::Installer.new(source: src, name: name, scope: "system", strict: true).run
    File.join(bundles_dir, name, "plugin", "plugin.rb")
  end

  def engine(**opts)
    Samagotchi::Engine.new(client: client, **opts)
  end

  def fire_before_turn(engine)
    event = {}
    engine.instance_variable_get(:@hooks).fire(:before_turn, event)
    event
  end

  it "loads a plugin at Engine start and its chi.on hook fires, labelled by the bundle" do
    install_plugin("marker", hook_plugin)
    event = fire_before_turn(engine)
    expect(event[:marks]).to eq(["hit", "plugin.rb (bundle marker)"])
    expect(engine.plugin_failures.any?).to be false
  end

  it "gives the plugin its bundle's settings from config.yml bundles:" do
    install_plugin("marker", hook_plugin)
    allow_any_instance_of(Samagotchi::ExtensionLoad).to receive(:bundle_settings).and_return("marker" => { "mark" => "custom" })
    expect(fire_before_turn(engine)[:marks].first).to eq("custom")
  end

  it "loads nothing with plugins: false" do
    install_plugin("marker", hook_plugin)
    expect(fire_before_turn(engine(plugins: false))[:marks]).to be_nil
  end

  describe "a plugin that can't load" do
    def expect_not_loaded(eng, reason)
      expect(fire_before_turn(eng)[:marks]).to be_nil
      failure = eng.plugin_failures.list.first
      expect(eng.guardrail_failures.any?).to be false
      expect(failure.what).to eq("plugin plugin.rb (bundle marker)")
      expect(failure.reason).to match(reason)
      expect(failure.required).to be false
    end

    it "is not loaded when edited after install, and it is announced (not fail-closed)" do
      path = install_plugin("marker", hook_plugin)
      File.write(path, hook_plugin.sub("hit", "tampered"))
      eng = nil
      expect { eng = engine }.to output(/bundle 'marker' plugin 'plugin.rb' not loaded: its sha256/).to_stderr
      expect_not_loaded(eng, /sha256/)
      expect(eng.plugin_failures.message).not_to include("denied")
    end

    it "is announced on the first turn labelled plugins, apart from the guardrails, and kept for the snapshot" do
      path = install_plugin("marker", hook_plugin)
      File.write(path, hook_plugin.sub("hit", "tampered"))
      eng = nil
      expect { eng = engine }.to output.to_stderr
      eng.guardrail_failures.add("hook g.rb (config)", "LoadError: x", required: false)
      expect(eng.plugin_warning).to be_nil
      events = []
      eng.send(:announce_guardrail_failures, ->(e) { events << e })

      expect(events.map { |e| [e[:label], e[:message][/\A\S+ \S+/]] }).to eq([[nil, "hook g.rb"], ["plugins", "plugin plugin.rb"]])
      expect(eng.plugin_warning).to start_with("plugin plugin.rb (bundle marker) failed to load (")
      expect(Samagotchi::TerminalUI::EventRenderer.load_warning_line(events.last)).to start_with("plugins> plugin plugin.rb")
    end

    it "is not loaded when chi doesn't meet requires_chi" do
      install_plugin("marker", hook_plugin, requires_chi: ">= 99.0")
      eng = nil
      expect { eng = engine }.to output(/not loaded: it requires chi >= 99.0/).to_stderr
      expect_not_loaded(eng, /requires chi/)
    end

    it "reports a syntax error" do
      install_plugin("marker", "class Plugin\n  def register(chi\nend\n")
      eng = nil
      expect { eng = engine }.to output(/not loaded: SyntaxError/).to_stderr
      expect_not_loaded(eng, /SyntaxError/)
    end

    it "reports a plugin that calls exit as it loads" do
      install_plugin("marker", "exit 1\n")
      eng = nil
      expect { eng = engine }.to output(/not loaded: SystemExit/).to_stderr
      expect_not_loaded(eng, /SystemExit/)
    end

    it "lets a signal raised as a plugin loads reach chi" do
      install_plugin("marker", "raise SignalException, \"TERM\"\n")
      expect { engine }.to raise_error(SignalException, "SIGTERM")
    end

    it "reports a class without #register" do
      install_plugin("marker", "class Plugin; end\n")
      eng = nil
      expect { eng = engine }.to output(/does not respond to #register/).to_stderr
      expect_not_loaded(eng, /#register/)
    end

    it "adds nothing when #register raises halfway" do
      install_plugin("marker", <<~RUBY)
        class Plugin
          def register(chi)
            chi.on(:before_turn) { |event| event[:marks] = ["early"] }
            raise "boom"
          end
        end
      RUBY
      eng = nil
      expect { eng = engine }.to output(/not loaded: RuntimeError: boom/).to_stderr
      expect_not_loaded(eng, /boom/)
    end

    it "doesn't stop the other bundles' plugins" do
      install_plugin("broken", "raise 'nope'\n")
      install_plugin("marker", hook_plugin)
      eng = nil
      expect { eng = engine }.to output(/bundle 'broken'/).to_stderr
      expect(fire_before_turn(eng)[:marks]).to eq(["hit", "plugin.rb (bundle marker)"])
    end
  end

  it "logs and skips a chi.on block that raises" do
    install_plugin("marker", <<~RUBY)
      class Plugin
        def register(chi)
          chi.on(:before_turn) { |_event| raise "hook boom" }
          chi.on(:before_turn) { |event| event[:after] = true }
        end
      end
    RUBY
    expect(fire_before_turn(engine)[:after]).to be true
  end

  it "logs a raising :generation_progress block once a minute, other events every time" do
    install_plugin("marker", <<~RUBY)
      class Plugin
        def register(chi)
          chi.on(:generation_progress) { |_event| raise "stream boom" }
          chi.on(:before_turn) { |_event| raise "turn boom" }
        end
      end
    RUBY
    failed = []
    allow(Samagotchi::Log).to receive(:warn).and_call_original
    allow(Samagotchi::Log).to receive(:warn).with(:plugins, "plugin_hook_failed", any_args) { |*_args, **fields| failed << fields[:event] }
    hooks = engine.instance_variable_get(:@hooks)

    3.times { hooks.fire(:generation_progress, { type: :generation_progress }) }
    2.times { hooks.fire(:before_turn, { type: :before_turn }) }

    expect(failed).to eq(%w[generation_progress before_turn before_turn])
  end

  it "tells every UI, when the first turn does, of a config.yml bundles: name nothing has, and still runs" do
    install_plugin("marker", hook_plugin)
    File.write(Samagotchi::ConfigFile.global_path, { "bundles" => { "markerr" => { "mark" => "x" }, "marker" => { "mark" => "y" } } }.to_yaml)
    eng = engine
    seen = []
    eng.subscribe(observer: ->(event) { seen << event })
    eng.announce_load_events!

    expect(seen.select { |event| event[:type] == :hook_notice }.map { |event| [event[:hook], event[:text], event[:level]] })
      .to eq([["config", "config.yml bundles: markerr: no installed bundle markerr (did you mean marker?)", :warn]])
  end

  describe "the bundles: warnings across Engines" do
    def config_bundles(*names) = File.write(Samagotchi::ConfigFile.global_path, { "bundles" => names.to_h { |name| [name, {}] } }.to_yaml)

    # What a new Engine (a new session, a respawn, a delegate) shows.
    def shown
      eng = engine
      seen = []
      eng.subscribe(observer: ->(event) { seen << event })
      eng.announce_load_events!
      seen.select { |event| event[:hook] == "config" }.map { |event| event[:text] }
    end

    let(:nope) { "config.yml bundles: nope: no installed bundle nope" }

    it "warns once for two Engines on the same config, and keeps logging" do
      config_bundles("nope")
      allow(Samagotchi::Log).to receive(:warn).and_call_original

      expect(shown).to eq([nope])
      expect(shown).to eq([])
      expect(Samagotchi::Log).to have_received(:warn).with(:config, "bundle_setting_unknown", msg: nope).twice
    end

    it "warns again on a changed finding" do
      config_bundles("nope")
      shown
      config_bundles("nope", "other")

      expect(shown).to eq([nope, "config.yml bundles: other: no installed bundle other"])
    end

    it "warns again when the findings went and came back" do
      config_bundles("nope")
      shown
      File.write(Samagotchi::ConfigFile.global_path, "{}\n")
      expect(shown).to eq([])
      expect(File.exist?(Samagotchi::BundleSettingsCheck.stamp_path)).to be(false)
      config_bundles("nope")

      expect(shown).to eq([nope])
    end

    it "warns every time, and still starts, on a stamp it can't read or write" do
      config_bundles("nope")
      FileUtils.mkdir_p(File.join(Samagotchi::BundleSettingsCheck.stamp_path, "in-the-way"))

      expect(shown).to eq([nope])
      expect(shown).to eq([nope])
    ensure
      FileUtils.rm_rf(Samagotchi::BundleSettingsCheck.stamp_path)
    end
  end

  it "tells the user once of a turn-scoped hook that raises, keeps logging it, and runs the next one" do
    eng = engine
    eng.announce_load_events!
    seen = []
    eng.subscribe(observer: ->(event) { seen << event })
    ran = []
    eng.register_hook(:before_turn) { raise "boom" }
    eng.register_hook(:before_turn) { ran << :next }
    allow(Samagotchi::Log).to receive(:exception).and_call_original

    2.times { eng.instance_variable_get(:@hooks).fire(:before_turn, { type: :before_turn }) }

    expect(seen.select { |event| event[:type] == :guardrail_warning }.map { |event| [event[:label], event[:message]] })
      .to eq([["plugins", "turn hook (before_turn) failed (RuntimeError: boom): it's skipped, and only the log has its next failures"]])
    expect(Samagotchi::Log).to have_received(:exception).with(:hooks, "hook_failed", kind_of(RuntimeError), any_args).twice
    expect(ran).to eq(%i[next next])
  end

  describe "a chi.on handler that raises" do
    let(:broken) do
      <<~RUBY
        class Plugin
          def register(chi)
            chi.on(:before_turn) { |_event, ctx| ctx.removed_api_call }
            chi.on(:after_turn) { raise "turn over\nsecond line" }
            chi.on(:session_end) { |event| event[:ran_after] = true }
          end
        end
      RUBY
    end
    let(:eng) do
      install_plugin("brk", broken)
      engine
    end
    let(:hooks) { eng.instance_variable_get(:@hooks) }
    let(:seen) { [] }

    def warnings = seen.select { |event| event[:type] == :guardrail_warning }

    before do
      eng.announce_load_events!
      eng.subscribe(observer: ->(event) { seen << event })
    end

    it "tells the user once per hook, on the plugins' surface, and logs every firing" do
      logged = []
      allow(Samagotchi::Log).to receive(:warn).and_call_original
      allow(Samagotchi::Log).to receive(:warn).with(:plugins, "plugin_hook_failed", any_args) { |*_args, **fields| logged << fields[:event] }

      3.times { hooks.fire(:before_turn, { type: :before_turn }) }
      2.times { hooks.fire(:after_turn, { type: :after_turn }) }

      expect(logged).to eq(%w[before_turn before_turn before_turn after_turn after_turn])
      expect(warnings.map { |event| event[:label] }).to eq(%w[plugins plugins])
      # Ruby 3.3 opens the quoted method name with a backtick, later Rubies with a quote.
      expect(warnings.first[:message].tr("`", "'")).to eq(
        "plugin.rb (bundle brk) before_turn hook failed (NoMethodError: undefined method 'removed_api_call' for an instance of " \
        "Samagotchi::Plugin::Context): it's skipped, and only the log has its next failures"
      )
      expect(warnings.last[:message]).to start_with("plugin.rb (bundle brk) after_turn hook failed (RuntimeError: turn over):")
    end

    it "shows a UI that joins later the same line (Bridge's snapshot)" do
      expect(eng.plugin_warning).to be_nil
      hooks.fire(:before_turn, { type: :before_turn })
      expect(eng.plugin_warning).to eq(warnings.first[:message])

      hooks.fire(:after_turn, { type: :after_turn })
      expect(eng.plugin_warning).to eq(warnings.map { |event| event[:message] }.join("; "))
    end

    it "stays fail-open: the event goes on to the next hook, and a failing notice costs nothing" do
      event = { type: :session_end }
      hooks.fire(:session_end, event)
      expect(event[:ran_after]).to be true

      allow(eng.instance_variable_get(:@hook_routes)).to receive(:guardrail_notify).and_raise("no UI")
      expect { hooks.fire(:before_turn, { type: :before_turn }) }.not_to raise_error
    end
  end

  describe "chi.service" do
    before { $plugin_service_log = [] }
    after { $plugin_service_log = nil }

    def service_plugin(eager:, fail_after: false)
      <<~RUBY
        class Plugin
          def register(chi)
            svc = chi.service(:srv, eager: #{eager}) do |s|
              $plugin_service_log << :started
              s.on_stop { $plugin_service_log << :stopped }
              :client
            end
            chi.command("/srv", "use it") { svc.value.to_s }
            raise "late boom" if #{fail_after}
          end
        end
      RUBY
    end

    it "starts an eager service at load" do
      install_plugin("svc", service_plugin(eager: true))
      engine
      expect($plugin_service_log).to eq([:started])
    end

    it "starts a lazy one on first use" do
      install_plugin("svc", service_plugin(eager: false))
      eng = engine
      expect($plugin_service_log).to eq([])
      expect(eng.command_registry.lookup("/srv").handler.call("")).to eq("client")
      expect($plugin_service_log).to eq([:started])
    end

    it "stops the services of a plugin whose load failed after starting them" do
      install_plugin("svc", service_plugin(eager: true, fail_after: true))
      expect { engine }.to output(/late boom/).to_stderr
      expect($plugin_service_log).to eq(%i[started stopped])
    end
  end

  it "gives #register the ctx; a notice or card shown as it loads waits for the first turn, after the load warnings" do
    install_plugin("broken", "raise 'nope'\n")
    install_plugin("starter", <<~RUBY)
      class Plugin
        def register(chi)
          chi.ctx.notify("server x didn't start", level: :warn)
          chi.ctx.card(title: "starter", body: "ready")
          chi.command("/starter", "x") { chi.ctx.settings.size.to_s }
        end
      end
    RUBY
    eng = nil
    expect { eng = engine }.to output(/bundle 'broken'/).to_stderr
    expect(eng.command_registry.lookup("/starter")).not_to be_nil
    events = []
    eng.send(:announce_guardrail_failures, ->(e) { events << e })

    expect(events.map { |e| e[:type] }).to eq(%i[guardrail_warning hook_notice card])
    expect(events[1]).to include(hook: "plugin.rb (bundle starter)", text: "server x didn't start", level: :warn)
    expect(events[2]).to include(source: "starter", title: "starter", in_turn: true)
  end
end
