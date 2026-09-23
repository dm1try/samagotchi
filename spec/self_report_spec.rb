# frozen_string_literal: true

require "spec_helper"
require "samagotchi/self_report"

RSpec.describe Samagotchi::SelfReport do
  let(:tmp) { Dir.mktmpdir("self-report") }
  let(:config_home) { File.join(tmp, "config") }
  let(:env) { { "XDG_CONFIG_HOME" => config_home, "XDG_STATE_HOME" => File.join(tmp, "state"), "HOME" => tmp } }

  def write_config(yaml)
    FileUtils.mkdir_p(File.join(config_home, "samagotchi"))
    File.write(File.join(config_home, "samagotchi", "config.yml"), yaml)
  end

  def field(name)
    described_class.fields(env: env).to_h.fetch(name)
  end

  # chi self's one server call (the served model's /props GET) answers
  # nothing unless a spec says otherwise.
  let(:props_answer) { nil }

  before do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = File.join(tmp, "bundles")
    probed = []
    @probed = probed
    answer = -> { props_answer }
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props) do |_client, model: nil|
      probed << model
      answer.call
    end
  end

  after do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    FileUtils.remove_entry(tmp)
  end

  it "reports the version and the source dir this code runs from" do
    expect(field("version")).to start_with(Samagotchi::VERSION)
    expect(field("source")).to eq("#{File.expand_path("../", __dir__)} (git checkout)")
  end

  it "resolves config and sessions from the XDG env it is given" do
    write_config("default:\n  model: spec-model\n")
    expect(field("config")).to eq(File.join(config_home, "samagotchi", "config.yml"))
    expect(field("sessions")).to eq(File.join(tmp, "state", "samagotchi", "sessions"))
  end

  it "resolves the memory dirs from the XDG env it is given" do
    memories = File.join(config_home, "samagotchi", "memories")
    expect(field("memories")).to eq(memories)
    expect(field("project memories")).to eq(File.join(memories, "projects", Samagotchi::MemoryPaths.project_key))
  end

  describe "desktop" do
    let(:plist) { File.join(tmp, "Applications", "Chi Helper.app", "Contents", "Info.plist") }

    def install_helper(version)
      FileUtils.mkdir_p(File.dirname(plist))
      File.write(plist, "<key>CFBundleShortVersionString</key>\n<string>#{version}</string>")
    end

    it "says not installed" do
      expect(field("desktop")).to eq("not installed")
    end

    it "says the helper matches this chi" do
      install_helper(Samagotchi::VERSION)
      expect(field("desktop")).to eq("#{Samagotchi::VERSION} (matches)")
    end

    it "says to upgrade when the helper is another version" do
      install_helper("0.0.1")
      expect(field("desktop")).to eq("0.0.1 (chi is #{Samagotchi::VERSION}: chi desktop upgrade)")
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

  it "reports the configured model with its host" do
    write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
    allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("spec-model")
    expect(field("model")).to eq("spec-model")
    expect(field("host")).to eq("main 10.0.0.5:8081")
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

      it "says so" do
        write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
        expect(field("served model")).to eq("unknown (no answer from the server's /props)")
      end
    end

    it "doesn't probe a remote host" do
      write_config("hosts:\n  or:\n    url: https://openrouter.ai/api/v1\n    api: openai\n    api_key_env: OR_KEY\n")

      expect(field("served model")).to eq("reported per turn (remote host)")
      expect(@probed).to eq([])
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
    expect(field("profile")).to eq("-")
  end

  it "lists installed bundles and the shipped system bundle version" do
    shipped = Samagotchi::MemoryBundle::Manifest.read(dir: Samagotchi::MemoryBundle::SystemBundle::GEM_BUNDLE_DIR).version
    expect(field("bundles")).to eq("(none installed; shipped system bundle #{shipped})")

    dir = File.join(tmp, "bundles", "samagotchi-system")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "manifest.json"), JSON.generate("name" => "samagotchi-system", "version" => "0.0.9"))
    expect(field("bundles")).to eq("samagotchi-system 0.0.9 (shipped #{shipped})")
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
