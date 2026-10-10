# frozen_string_literal: true

require "spec_helper"
require "samagotchi/self_report"
require "samagotchi/engine"

RSpec.describe Samagotchi::SelfReport do
  let(:tmp) { Dir.mktmpdir("self-report") }
  let(:config_home) { File.join(tmp, "config") }
  let(:bundles_dir) { File.join(config_home, "samagotchi", "memories", ".bundles") }
  let(:env) { { "XDG_CONFIG_HOME" => config_home, "XDG_STATE_HOME" => File.join(tmp, "state"), "HOME" => tmp } }
  # chi self's one server call (the served model's /props GET) answers
  # nothing unless a spec says otherwise.
  let(:props_answer) { nil }
  # ...and no chi web answers, unless a spec says otherwise.
  let(:web_info) { nil }

  def write_config(yaml)
    FileUtils.mkdir_p(File.join(config_home, "samagotchi"))
    File.write(File.join(config_home, "samagotchi", "config.yml"), yaml)
  end

  def field(name)
    described_class.fields(env: env).to_h.fetch(name)
  end

  before do
    info = -> { web_info }
    allow(Samagotchi::LiveVersions).to receive(:web_info) { info.call }
    probed = []
    @probed = probed
    answer = -> { props_answer }
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props) do |_client, model: nil|
      probed << model
      answer.call
    end
    # A local chat host's /models probe answers nothing unless a spec says
    # otherwise (no real network in specs).
    allow_any_instance_of(Samagotchi::LLM::HTTP).to receive(:fetch).and_raise(Errno::ECONNREFUSED)
  end

  around { |example| with_env("XDG_CONFIG_HOME" => config_home) { example.run } }

  after { FileUtils.remove_entry(tmp) }

  it "reports the version and the source dir this code runs from" do
    expect(field("version")).to start_with(Samagotchi::VERSION)
    expect(field("source")).to eq("#{File.expand_path("../", __dir__)} (git checkout)")
  end

  it "resolves config and sessions from the XDG env it is given" do
    write_config("default:\n  model: spec-model\n")
    expect(field("config")).to eq(File.join(config_home, "samagotchi", "config.yml"))
    expect(field("sessions")).to eq(File.join(tmp, "state", "samagotchi", "sessions"))
  end

  it "names the debug log next to the sessions dir, or says it is off" do
    expect(field("log")).to eq(File.join(tmp, "state", "samagotchi", "samagotchi.log"))
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("log.disable").and_return(true)
    expect(field("log")).to eq("(disabled: log.disable)")
  end

  it "resolves the memory dirs from the XDG env it is given" do
    memories = File.join(config_home, "samagotchi", "memories")
    expect(field("memories")).to eq(memories)
    expect(field("project memories")).to eq(File.join(memories, "projects", Samagotchi::MemoryPaths.project_key))
  end

  it "sizes both memory indexes as the prompt carries them, marking one over memory.index_warn_tokens" do
    memories = File.join(config_home, "samagotchi", "memories")
    project = File.join(memories, "projects", Samagotchi::MemoryPaths.project_key)
    FileUtils.mkdir_p(project)
    system_index = "- **a** · 9 B · 2026-10-08 · #{"x" * 4000}\n- **b** · 9 B\n"
    File.write(File.join(memories, "index.md"), system_index)
    File.write(File.join(project, "index.md"), "- **p** · 3 B · tip\n")
    expect((system_index.length / 4.0).ceil).to eq(1011)
    expect(field("memory index")).to eq("system ~1.0k tokens (2 lines), project ~5 tokens (1 line)")
    with_env("SAMAGOTCHI_MEMORY_INDEX_WARN_TOKENS" => "1000") do
      expect(field("memory index")).to eq("system ~1.0k tokens (2 lines, over 1000), project ~5 tokens (1 line)")
    end
  end

  describe "chi web" do
    it "says it isn't running" do
      expect(field("chi web")).to eq("not running on port 4567")
    end

    context "when one runs on this machine only" do
      let(:web_info) { { "app" => "chi-web", "lan" => nil } }

      it { expect(field("chi web")).to eq("on 127.0.0.1:4567 (this machine only)") }
    end

    context "when one runs on the LAN" do
      let(:web_info) { { "app" => "chi-web", "lan" => "192.168.1.55" } }

      it "names the address, probing 127.0.0.1 even with web.host lan" do
        allow(Samagotchi::Config).to receive(:get).and_call_original
        allow(Samagotchi::Config).to receive(:get).with("web.host").and_return("lan")
        allow(Samagotchi::Config).to receive(:get).with("web.port").and_return(4999)

        expect(field("chi web")).to eq("LAN on 192.168.1.55:4999 (and 127.0.0.1)")
        expect(Samagotchi::LiveVersions).to have_received(:web_info).with("127.0.0.1", 4999, timeout: 0.3)
      end
    end
  end

  describe "desktop" do
    let(:plist) { File.join(tmp, "Applications", "Chi Helper.app", "Contents", "Info.plist") }

    def install_helper(version)
      FileUtils.mkdir_p(File.dirname(plist))
      File.write(plist, "<key>CFBundleShortVersionString</key>\n<string>#{version}</string>")
    end

    # The helper itself is macOS-only; these read its plist, which works anywhere.
    before { allow(Samagotchi::Desktop).to receive(:supported?).and_return(true) }

    it "says not installed" do
      expect(field("desktop")).to eq("not installed")
    end

    it "says the helper matches this chi" do
      install_helper(Samagotchi::VERSION)
      expect(field("desktop")).to eq("#{Samagotchi::VERSION} (matches)")
    end

    it "says chi update when the helper is another version built from other sources" do
      install_helper("0.0.1")
      expect(field("desktop")).to eq("0.0.1 (chi is #{Samagotchi::VERSION}: chi update)")
    end

    it "says an older helper is up to date when its sources are unchanged" do
      install_helper("0.0.1")
      helper = Samagotchi::Desktop::MacOS.new(env: { "HOME" => tmp })
      FileUtils.mkdir_p(File.dirname(helper.launch_path))
      File.write(helper.launch_path, JSON.generate("version" => "0.0.1", "argv" => [RbConfig.ruby], "sources_sha" => helper.sources_sha))
      expect(field("desktop")).to eq("0.0.1 (up to date for chi #{Samagotchi::VERSION})")
    end

    it "says macOS only elsewhere" do
      allow(Samagotchi::Desktop).to receive(:supported?).and_return(false)
      expect(field("desktop")).to eq("- (macOS only)")
    end
  end

  it "flags a missing config file" do
    expect(field("config")).to end_with("config.yml (missing)")
  end

  it "reports the hooks dir from config, expanding ~ against HOME" do
    write_config("hooks:\n  hooks_dir: \"~/my_hooks/\"\n")
    expect(field("hooks dir")).to eq(File.join(tmp, "my_hooks/"))
  end

  it "falls back to the hooks dir next to config.yml" do
    expect(field("hooks dir")).to eq(File.join(config_home, "samagotchi/hooks/"))
  end

  it "names the host's API key variable and whether it is set, never the key" do
    write_config("hosts:\n  fw:\n    url: https://api.example.test/v1\n    api: openai\n    api_key_env: EXAMPLE_KEY\n")
    allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("fw:m")

    expect(field("api key")).to eq("EXAMPLE_KEY (unset)")
    env["EXAMPLE_KEY"] = "sk-secret"
    expect(field("api key")).to eq("EXAMPLE_KEY (set)")
    expect(described_class.text(env: env)).not_to include("sk-secret")
    expect(field("host")).to eq("fw https://api.example.test/v1 as m")
  end

  it "shows no API key variable for a local host" do
    write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
    allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("spec-model")

    expect(field("api key")).to eq("-")
  end

  it "reports the fallback context window and its source (the server's own window wins at runtime)" do
    expect(field("context window")).to eq("256000 (default; the server's n_ctx wins at runtime)")

    write_config("context:\n  window_tokens: 64000\n")
    expect(field("context window")).to eq("64000 (config; the server's n_ctx wins at runtime)")

    env["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"] = "32000"
    expect(field("context window")).to eq("32000 (env; the server's n_ctx wins at runtime)")
  end

  it "reports the current model's own window, else its host's, over the global one, and says which" do
    allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("spec-model")
    write_config("hosts:\n  main:\n    host: 10.0.0.5\n    window_tokens: 48000\n" \
                 "models:\n  spec-model:\n    window_tokens: 96000\ncontext:\n  window_tokens: 64000\n")
    expect(field("context window")).to eq("96000 (models: spec-model; the server's n_ctx wins at runtime)")

    write_config("hosts:\n  main:\n    host: 10.0.0.5\n    window_tokens: 48000\ncontext:\n  window_tokens: 64000\n")
    expect(field("context window")).to eq("48000 (hosts.main; the server's n_ctx wins at runtime)")

    write_config("hosts:\n  main:\n    host: 10.0.0.5\ncontext:\n  window_tokens: 64000\n")
    expect(field("context window")).to eq("64000 (config; the server's n_ctx wins at runtime)")
  end

  it "reports the configured model with its host" do
    write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
    allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("spec-model")
    expect(field("model")).to eq("spec-model (default)")
    expect(field("host")).to eq("main 10.0.0.5:8081")
  end

  describe "the session's model (SAMAGOTCHI_SESSION_MODEL, set for execute children)" do
    let(:two_hosts) do
      "hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n  " \
        "splash:\n    host: 10.0.0.6\n    port: 8082\n    api: openai\n"
    end

    before do
      write_config(two_hosts)
      allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("main:spec-model")
    end

    it "labels the default outside a session" do
      expect(field("model")).to eq("main:spec-model (default)")
    end

    it "names this session's model, with the default, and derived rows follow it" do
      env.merge!("SAMAGOTCHI_SESSION_MODEL" => "splash:Qwen3.8-27B", "SAMAGOTCHI_PARENT_SESSION" => "abcd1234ef")

      expect(field("model")).to eq("splash:Qwen3.8-27B (this session abcd1234; default main:spec-model)")
      expect(field("host")).to eq("splash 10.0.0.6:8082 as Qwen3.8-27B")
      expect(field("loop")).to eq("chat (api: openai)")
      expect(field("served model")).to eq("down (the server didn't answer; is it running?)")
      expect(@probed).to eq([])
    end

    it "says when the session runs the default" do
      env.merge!("SAMAGOTCHI_SESSION_MODEL" => "main:spec-model", "SAMAGOTCHI_PARENT_SESSION" => "abcd1234ef")
      expect(field("model")).to eq("main:spec-model (this session abcd1234, the default)")
    end

    it "leaves out the session id when there is none (a REPL without a session)" do
      env.merge!("SAMAGOTCHI_SESSION_MODEL" => "splash:Qwen3.8-27B", "SAMAGOTCHI_PARENT_SESSION" => "chi")
      expect(field("model")).to eq("splash:Qwen3.8-27B (this session; default main:spec-model)")
    end

    it "names the memory overlay key of the model it reports" do
      expect(field("model key")).to eq("spec-model")
      env["SAMAGOTCHI_SESSION_MODEL"] = "splash:Qwen3.8-27B"
      expect(field("model key")).to eq("qwen3-8-27b")
    end

    it "names the model notes the model's prompt loads, without the session's muted ones, none when none match" do
      memories = File.join(config_home, "samagotchi", "memories")
      FileUtils.mkdir_p(memories)
      File.write(File.join(memories, "model_notes_qwen.md"), "models: qwen3*\nQWEN HABITS\n")
      File.write(File.join(memories, "model_notes_spec.md"), "models: spec-*\nSPEC\n")
      expect(field("model notes")).to eq("model_notes_spec (system, 4 chars)")

      env["SAMAGOTCHI_SESSION_MODEL"] = "splash:Qwen3.8-27B"
      expect(field("model notes")).to eq("model_notes_qwen (system, 11 chars)")

      session = Samagotchi::Session.new_session(mode: "assist", model_name: "splash:Qwen3.8-27B", working_directory: tmp,
                                                muted_memory_names: ["model_notes_qwen"])
      session.save(state_dir: Samagotchi::Session.default_state_dir(env: env))
      env["SAMAGOTCHI_PARENT_SESSION"] = session.id
      expect(field("model notes")).to eq("none")
    end

    it "names a note's fallback overlay when the session's model was typed as an alias, as the Engine does" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\nmodel_aliases:\n  fast: main:small\n")
      allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("main:small")
      memories = File.join(config_home, "samagotchi", "memories")
      FileUtils.mkdir_p(memories)
      File.write(File.join(memories, "model_notes_alias.md"), "models: small*\nSPEC\n")
      File.write(File.join(memories, "model_notes_alias.fast.md"), "Alias guidance.\n")
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "main:small", model_typed: "fast",
                                                working_directory: tmp)
      session.save(state_dir: Samagotchi::Session.default_state_dir(env: env))
      env["SAMAGOTCHI_SESSION_MODEL"] = "main:small"
      env["SAMAGOTCHI_PARENT_SESSION"] = session.id

      engine = Samagotchi::Engine.new(host_registry: Samagotchi::HostRegistry.new(env: env),
                                      model_name: "main:small", model_typed: "fast", plugins: false)

      expect(engine.model_key).to eq("small")
      expect(field("model notes")).to eq(Samagotchi::PromptNote.text(engine.prompt_notes))
      # The row counts the base note *and* the typed alias's overlay (the
      # base alone would be "SPEC".length).
      expect(field("model notes")).to eq("model_notes_alias (system, #{engine.model_notes.first.chars} chars)")
      expect(engine.model_notes.first.chars).to be > "SPEC".length
      expect(engine.model_notes.first.body).to include("Alias guidance.")
    end

    it "gives no size warning for a large model note (the prompt's build does)" do
      memories = File.join(config_home, "samagotchi", "memories")
      FileUtils.mkdir_p(memories)
      File.write(File.join(memories, "model_notes_big.md"), "models: spec-*\n#{"x" * 3_100}\n")
      expect(Samagotchi::Log).not_to receive(:warn).with(:memory, "model_notes_large", anything)
      expect(field("model notes")).to eq("model_notes_big (system, 3100 chars)")
    end

    it "puts the model key right after the model row" do
      labels = described_class.fields(env: env).map(&:first)
      expect(labels[labels.index("model") + 1]).to eq("model key")
    end

    it "keeps chi self --model on the default (what a new session starts on)" do
      env["SAMAGOTCHI_SESSION_MODEL"] = "splash:Qwen3.8-27B"
      expect(described_class.model_ref_name(env: env)).to eq("main:spec-model")
    end
  end

  describe "the served model row (one short /props probe)" do
    before { allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("spec-model") }

    def props(body) = Samagotchi::Client::ServerProps.new(body: body, status: :ok)

    context "when llama.cpp serves another model than configured" do
      let(:props_answer) { props("model_alias" => "ornith-1.5") }

      it "names it, and the configured one it answers for" do
        write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")

        expect(field("served model")).to eq("ornith-1.5 (not spec-model: the server serves its own model)")
        expect(@probed).to eq(["spec-model"])
      end

      it "names it alone when the host's models: entry expects it (served:)" do
        write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n    models:\n      spec-model: {served: [ornith-1.5]}\n")

        expect(field("served model")).to eq("ornith-1.5")
      end
    end

    context "when it serves the configured model" do
      let(:props_answer) { props("model_alias" => "spec-model") }

      it "names it alone" do
        write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
        expect(field("served model")).to eq("spec-model")
      end
    end

    context "when the server doesn't answer" do
      let(:props_answer) { Samagotchi::Client::ServerProps.new(body: nil, status: :network_error) }

      it "asks whether it is running" do
        write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
        expect(field("served model")).to eq("unknown (the server didn't answer; is it running?)")
      end
    end

    context "when the server answers /props with an error" do
      let(:props_answer) { Samagotchi::Client::ServerProps.new(body: nil, status: :http_error) }

      it "says the server reports it per turn (a server without /props, as the engine reads it)" do
        write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
        expect(field("served model")).to eq("reported per turn (the server has no /props)")
      end
    end

    context "when /props answers without a model" do
      let(:props_answer) { props({}) }

      it "says it had no answer there" do
        write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
        expect(field("served model")).to eq("unknown (no answer from the server's /props)")
      end
    end

    it "probes a local chat host's /models instead of /props" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8082\n    api: openai\n")

      expect(field("served model")).to eq("down (the server didn't answer; is it running?)")
      expect(@probed).to eq([])
    end

    it "doesn't probe a remote host" do
      write_config("hosts:\n  or:\n    url: https://openrouter.ai/api/v1\n    api: openai\n    api_key_env: OR_KEY\n")

      expect(field("served model")).to eq("reported per turn (remote host)")
      expect(@probed).to eq([])
    end
  end

  describe "the served model row for a local chat host (api: openai)" do
    before { allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("spec-model") }

    # A local chat host has no /props: chi self GETs <base>/models with the
    # native probe's short timeouts.
    def stub_models(status: 200, body: nil, raise_error: nil)
      response = Net::HTTPResponse::CODE_TO_OBJ[status.to_s].new("1.1", status.to_s, "")
      allow_any_instance_of(Samagotchi::LLM::HTTP).to receive(:fetch) do |_http, _uri, _req, **_opts|
        raise raise_error if raise_error

        allow(response).to receive(:body).and_return(body.to_s)
        response
      end
    end

    it "reports up with the ids it serves" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8082\n    api: openai\n")
      stub_models(body: JSON.generate(data: [{ id: "spec-model" }, { id: "other" }]))

      expect(field("served model")).to eq("up: spec-model, other")
    end

    it "marks the configured model when the list doesn't have it" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8082\n    api: openai\n")
      stub_models(body: JSON.generate(data: [{ id: "other" }]))

      expect(field("served model")).to eq("up: other (not spec-model)")
    end

    it "reports down when the server doesn't answer" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8082\n    api: openai\n")
      stub_models(raise_error: Errno::ECONNREFUSED)

      expect(field("served model")).to eq("down (the server didn't answer; is it running?)")
    end

    it "reports down with the status on an error response" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8082\n    api: openai\n")
      stub_models(status: 500, body: "boom")

      expect(field("served model")).to eq("down (HTTP 500)")
    end

    it "says up with no models when the list is empty" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8082\n    api: openai\n")
      stub_models(body: JSON.generate(data: []))

      expect(field("served model")).to eq("up (no models listed)")
    end
  end

  describe "the thinking row" do
    before { allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("spec-model") }

    it "shows the model's level with where it came from, default without one" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    thinking: low\nmodels:\n  spec-model:\n    thinking: off\n")
      expect(field("thinking")).to eq("off (models: spec-model)")

      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    thinking: low\n")
      expect(field("thinking")).to eq("low (hosts.main)")

      write_config("hosts:\n  main:\n    host: 10.0.0.5\n")
      expect(field("thinking")).to eq("default")
    end

    it "puts the session's own level first in a session's commands (SAMAGOTCHI_SESSION_THINKING), not outside one" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    thinking: low\n")
      env["SAMAGOTCHI_SESSION_THINKING"] = "high"
      expect(field("thinking")).to eq("low (hosts.main)")

      env["SAMAGOTCHI_SESSION_MODEL"] = "main:spec-model"
      expect(field("thinking")).to eq("high (session)")
    end

    it "finds models: under the model an alias points at, as a turn does" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\nmodel_aliases:\n  fast: org/Fast-1\n" \
                   "models:\n  org/fast-1:\n    thinking: off\n")
      allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("fast")

      expect(field("thinking")).to eq("off (models: org/fast-1)")
    end
  end

  describe "the profile row (offline: no server probe)" do
    before { allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("spec-model") }

    it "says a native llama.cpp host's template decides at runtime, and what the name gives otherwise" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
      expect(field("profile")).to eq("from the server at runtime (default #{Samagotchi::ModelProfile::DEFAULT_NAME})")

      allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("my-gemma")
      expect(field("profile")).to eq("from the server at runtime (name says gemma4)")
    end

    it "shows a configured profile with where it came from" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    profile: gemma4\nmodels:\n  spec-model:\n    profile: qwen36\n")
      expect(field("profile")).to eq("qwen36 (config models: spec-model)")

      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    profile: gemma4\n")
      expect(field("profile")).to eq("gemma4 (config hosts.main)")

      env["SAMAGOTCHI_MODEL_PROFILE"] = "qwen36"
      expect(field("profile")).to eq("qwen36 (env)")
    end

    it "finds models: under the alias typed after a host prefix" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\nmodel_aliases:\n  small: org/Small-1\nmodels:\n  small:\n    profile: gemma4\n")
      allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("main:small")
      # HostRegistry#host_for_model reads aliases from the global config, not env.
      saved = ENV["XDG_CONFIG_HOME"]
      ENV["XDG_CONFIG_HOME"] = config_home

      expect(field("profile")).to eq("gemma4 (config models: small)")
    ensure
      ENV["XDG_CONFIG_HOME"] = saved
    end

    it "names mlx's profile directly (no template to read) and a chat host's as name-based" do
      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    transport: mlx\n")
      expect(field("profile")).to eq("#{Samagotchi::ModelProfile::DEFAULT_NAME} (default)")

      write_config("hosts:\n  main:\n    host: 10.0.0.5\n    api: openai\n")
      expect(field("profile")).to eq("name-based (chat API: only strips thoughts)")
    end

    it "comes right after the loop row" do
      labels = described_class.fields(env: env).map(&:first)
      expect(labels[labels.index("loop") + 1]).to eq("profile")
    end
  end

  it "says so when no model is configured" do
    allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_raise(ArgumentError)
    expect(field("model")).to eq("(not configured)")
    expect(field("host")).to eq("-")
    expect(field("model key")).to eq("-")
    expect(field("profile")).to eq("-")
  end

  it "lists installed bundles and the shipped system bundle version" do
    shipped = Samagotchi::MemoryBundle::Manifest.read(dir: Samagotchi::MemoryBundle::SystemBundle::GEM_BUNDLE_DIR).version
    expect(field("bundles")).to eq("(none installed; shipped system bundle #{shipped})")

    dir = File.join(bundles_dir, "samagotchi-system")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "manifest.json"), JSON.generate("name" => "samagotchi-system", "version" => "0.0.9"))
    expect(field("bundles")).to eq("samagotchi-system 0.0.9 (shipped #{shipped})")
  end

  it "lists every bundle with a manifest.json by name, '?' for a version it can't read" do
    { "zeta" => JSON.generate("version" => "2.0"), "broken" => "{", "list" => "[]", "nover" => "{}" }.each do |name, body|
      FileUtils.mkdir_p(File.join(bundles_dir, name))
      File.write(File.join(bundles_dir, name, "manifest.json"), body)
    end
    FileUtils.mkdir_p(File.join(bundles_dir, "empty"))
    FileUtils.mkdir_p(File.join(bundles_dir, ".hidden"))
    File.write(File.join(bundles_dir, ".hidden", "manifest.json"), "{}")
    expect(field("bundles")).to eq("broken ?, list ?, nover ?, zeta 2.0")
  end

  describe ".install_kind" do
    it "is 'installed gem' under a gem path" do
      dir = File.join(Gem.path.first, "gems", "samagotchi-9.9.9")
      expect(described_class.install_kind(dir)).to eq("installed gem")
    end

    it "is 'directory' for a plain dir" do
      expect(described_class.install_kind(tmp)).to eq("directory")
    end
  end

  it "renders one aligned line per field" do
    lines = described_class.text(env: env).lines
    expect(lines.size).to eq(described_class.fields(env: env).size)
    expect(lines.first).to match(/\Aversion\s{2,}\S/)
  end
end
