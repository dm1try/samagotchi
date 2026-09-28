# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/config"
require "samagotchi/model_profile"
require "samagotchi/client"

RSpec.describe Samagotchi::ConfigFile do
  around do |example|
    original_env = {
      "XDG_CONFIG_HOME" => ENV["XDG_CONFIG_HOME"],
      "SAMAGOTCHI_DEFAULT_MODEL" => ENV["SAMAGOTCHI_DEFAULT_MODEL"],
      "SAMAGOTCHI_SERVER_HOST" => ENV["SAMAGOTCHI_SERVER_HOST"],
      "SAMAGOTCHI_SERVER_PORT" => ENV["SAMAGOTCHI_SERVER_PORT"]
    }

    begin
      ENV.delete("XDG_CONFIG_HOME")
      ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
      ENV.delete("SAMAGOTCHI_SERVER_HOST")
      ENV.delete("SAMAGOTCHI_SERVER_PORT")
      example.run
    ensure
      original_env.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
    end
  end

  describe ".global_path" do
    it "uses XDG_CONFIG_HOME when set" do
      ENV["XDG_CONFIG_HOME"] = "/tmp/xdg-home"

      expect(described_class.global_path).to eq("/tmp/xdg-home/samagotchi/config.yml")
    end

    describe Samagotchi::Config do
      it "defaults web Markdown rendering to disabled" do
        expect(described_class.snapshot(file_data: {}, env: {}, cli_overrides: {}).fetch("web.markdown")).to be(false)
      end

      it "defaults the web turn view to on, off from the file, env or cli" do
        expect(described_class.snapshot(file_data: {}, env: {}, cli_overrides: {}).fetch("web.turn_view")).to be(true)
        expect(described_class.resolve("web.turn_view", file_data: { "web" => { "turn_view" => false } }, env: {})).to be(false)
        expect(described_class.resolve("web.turn_view", file_data: {}, env: { "SAMAGOTCHI_WEB_TURN_VIEW" => "0" })).to be(false)
        expect(described_class.resolve("web.turn_view", file_data: {}, env: {}, cli_overrides: { "web.turn_view" => false })).to be(false)
        expect(described_class.find_by_key("web.turn_view").cli_flag).to eq("--web-turn-view")
      end

      it "defaults the annotate presets to two, set from the file, env or cli; \"\" is none but not from env" do
        key = "web.annotate_presets"
        expect(described_class.snapshot(file_data: {}, env: {}, cli_overrides: {}).fetch(key)).to eq("Agreed|Could you please elaborate?")
        expect(described_class.resolve(key, file_data: { "web" => { "annotate_presets" => "Yes|No" } }, env: {})).to eq("Yes|No")
        expect(described_class.resolve(key, file_data: { "web" => { "annotate_presets" => %w[Yes Why?] } }, env: {})).to eq("Yes|Why?")
        expect(described_class.resolve(key, file_data: {}, env: { "SAMAGOTCHI_WEB_ANNOTATE_PRESETS" => "Ok" })).to eq("Ok")
        expect(described_class.resolve(key, file_data: {}, env: {}, cli_overrides: { key => "A|B" })).to eq("A|B")
        expect(described_class.find_by_key(key).cli_flag).to eq("--web-annotate-presets")
        expect(described_class.resolve(key, file_data: {}, env: {}, cli_overrides: { key => "" })).to eq("")
        expect(described_class.resolve(key, file_data: { "web" => { "annotate_presets" => "" } }, env: {})).to eq("")
        expect(described_class.resolve(key, file_data: {}, env: { "SAMAGOTCHI_WEB_ANNOTATE_PRESETS" => "" })).to eq("Agreed|Could you please elaborate?")
      end

      it "defaults a worker's idle exit to 30 minutes, overridable in fractions" do
        expect(described_class.resolve("session.idle_exit_minutes", file_data: {}, env: {})).to eq(30.0)
        expect(described_class.resolve("session.idle_exit_minutes", file_data: {},
                                       env: { "SAMAGOTCHI_SESSION_IDLE_EXIT_MINUTES" => "0.2" })).to eq(0.2)
      end

      it "caps a session's running delegates at 4, from the file or the env, with no CLI flag" do
        expect(described_class.resolve("session.max_children", file_data: {}, env: {})).to eq(4)
        expect(described_class.resolve("session.max_children", file_data: {}, env: { "SAMAGOTCHI_SESSION_MAX_CHILDREN" => "1" })).to eq(1)
        expect(described_class.resolve("session.max_children", file_data: { "session" => { "max_children" => 2 } }, env: {})).to eq(2)
        expect(described_class.cli_entries.map(&:key)).not_to include("session.max_children")
      end

      it "runs plain chi attached unless session.shared is turned off" do
        expect(described_class.resolve("session.shared", file_data: {}, env: {})).to be(true)
        expect(described_class.resolve("session.shared", file_data: {}, env: { "SAMAGOTCHI_SESSION_SHARED" => "0" })).to be(false)
        expect(described_class.resolve("session.shared", file_data: { "session" => { "shared" => false } }, env: {})).to be(false)
        expect(described_class.cli_entries.map(&:key)).not_to include("session.shared")
      end
    end

    it "falls back to ~/.config" do
      expect(described_class.global_path(env: {})).to eq(File.expand_path("~/.config/samagotchi/config.yml"))
    end
  end

  describe ".load_global_env!" do
    it "loads nested scalar values and leaves existing env untouched" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        config_dir = File.join(dir, "samagotchi")
        Dir.mkdir(config_dir)
        File.write(File.join(config_dir, "config.yml"), <<~YAML)
          SAMAGOTCHI_DEFAULT_MODEL: Qwen3-14B-Instruct
          server:
            host: 192.0.2.10
            port: 8081
        YAML

        ENV["XDG_CONFIG_HOME"] = dir
        ENV["SAMAGOTCHI_SERVER_PORT"] = "9090"

        expect(described_class.load_global_env!).to be(true)
        expect(Samagotchi::ModelProfile.from_env.name).to eq("qwen36")
        expect(ENV["SAMAGOTCHI_DEFAULT_MODEL"]).to eq("Qwen3-14B-Instruct")

        client = Samagotchi::Client.new
        expect(client.instance_variable_get(:@host)).to eq("192.0.2.10")
        expect(client.instance_variable_get(:@port)).to eq(9090)
      end
    end

    it "returns false when the config file does not exist" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        ENV["XDG_CONFIG_HOME"] = dir

        expect(described_class.load_global_env!).to be(false)
      end
    end

    it "skips non-scalar values (e.g., nested sections) instead of raising" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        config_dir = File.join(dir, "samagotchi")
        Dir.mkdir(config_dir)
        File.write(File.join(config_dir, "config.yml"), <<~YAML)
          SAMAGOTCHI_DEFAULT_MODEL: Qwen3-14B-Instruct
          hooks:
            hooks_dir: ~/.config/samagotchi/hooks/
            before_turn:
              - path: audit.rb
        YAML

        ENV["XDG_CONFIG_HOME"] = dir

        expect(described_class.load_global_env!).to be(true)
        expect(ENV["SAMAGOTCHI_DEFAULT_MODEL"]).to eq("Qwen3-14B-Instruct")
        # Non-scalar hooks section is skipped for env-loading
        expect(ENV).not_to have_key("hooks")
      end
    end

    it "loads SAMAGOTCHI_DEFAULT_INPUT as a scalar string" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        config_dir = File.join(dir, "samagotchi")
        Dir.mkdir(config_dir)
        File.write(File.join(config_dir, "config.yml"), <<~YAML)
          SAMAGOTCHI_DEFAULT_INPUT: "Please "
        YAML

        ENV["XDG_CONFIG_HOME"] = dir

        expect(described_class.load_global_env!).to be(true)
        expect(ENV["SAMAGOTCHI_DEFAULT_INPUT"]).to eq("Please ")
      end
    end
  end

  describe ".read_yaml" do
    around do |example|
      ENV.delete("XDG_CONFIG_HOME")
      example.run
    ensure
      ENV.delete("XDG_CONFIG_HOME")
    end

    it "returns nil for a missing file" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        ENV["XDG_CONFIG_HOME"] = dir
        expect(described_class.read_yaml).to be_nil
      end
    end

    it "memoises per (path, mtime, size) and refreshes on change" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        config_dir = File.join(dir, "samagotchi")
        Dir.mkdir(config_dir)
        path = File.join(config_dir, "config.yml")
        File.write(path, "default:\n  model: alpha\n")
        ENV["XDG_CONFIG_HOME"] = dir

        first = described_class.read_yaml
        second = described_class.read_yaml
        expect(second).to equal(first) # same parsed object — cache hit
        expect(first).to eq("default" => { "model" => "alpha" })

        File.write(path, "default:\n  model: beta\n")
        expect(described_class.read_yaml).to eq("default" => { "model" => "beta" })
      end
    end
  end

  describe ".preloaded_memories" do
    around do |example|
      ENV.delete("XDG_CONFIG_HOME")
      example.run
    ensure
      ENV.delete("XDG_CONFIG_HOME")
    end

    def write_memories_yaml(dir, body)
      config_dir = File.join(dir, "samagotchi")
      Dir.mkdir(config_dir)
      File.write(File.join(config_dir, "config.yml"), body)
      ENV["XDG_CONFIG_HOME"] = dir
    end

    it "returns [] when the file is missing" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        ENV["XDG_CONFIG_HOME"] = dir
        expect(described_class.preloaded_memories).to eq([])
      end
    end

    it "returns [] when the section is absent" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        write_memories_yaml(dir, "SAMAGOTCHI_DEFAULT_MODEL: Gemma-4B-it\n")
        expect(described_class.preloaded_memories).to eq([])
      end
    end

    it "returns [] when the section is false" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        write_memories_yaml(dir, "memories: false\n")
        expect(described_class.preloaded_memories).to eq([])
      end
    end

    it "parses a YAML list of strings, preserving order" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        write_memories_yaml(dir, <<~YAML)
          memories:
            - identity
            - system/user_preferences
        YAML
        expect(described_class.preloaded_memories).to eq(%w[identity system/user_preferences])
      end
    end

    it "accepts a single comma-separated string and splits commas inside list items" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        write_memories_yaml(dir, <<~YAML)
          memories:
            - "alpha, beta"
            - gamma
        YAML
        expect(described_class.preloaded_memories).to eq(%w[alpha beta gamma])
      end
    end

    it "accepts a bare scalar string (single entry)" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        write_memories_yaml(dir, "memories: solo\n")
        expect(described_class.preloaded_memories).to eq(["solo"])
      end
    end

    it "strips whitespace and drops empty items" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        write_memories_yaml(dir, <<~YAML)
          memories:
            - "  padded  "
            - ""
            - "a,,b"
        YAML
        expect(described_class.preloaded_memories).to eq(%w[padded a b])
      end
    end
  end

  describe "recap.sentences" do
    def resolve(**opts) = Samagotchi::Config.resolve("recap.sentences", env: {}, **opts)

    it "is unset by default and read from env, file and cli, cli first" do
      expect(resolve).to be_nil
      expect(resolve(env: { "SAMAGOTCHI_RECAP_SENTENCES" => "2-3" })).to eq("2-3")
      expect(resolve(file_data: { "recap" => { "sentences" => 3 } })).to eq("3")
      expect(resolve(env: { "SAMAGOTCHI_RECAP_SENTENCES" => "2-3" }, cli_overrides: { "recap.sentences" => "5-7" })).to eq("5-7")
      expect(Samagotchi::Config.find_by_key("recap.sentences").cli_flag).to eq("--recap-sentences")
    end
  end

  describe ".recap_config" do
    around do |example|
      recap_env_keys = %w[
        XDG_CONFIG_HOME SAMAGOTCHI_RECAP_ENABLED SAMAGOTCHI_RECAP_BASE_URL
        SAMAGOTCHI_RECAP_MODEL SAMAGOTCHI_RECAP_HOST_REF SAMAGOTCHI_RECAP_INACTIVITY
        SAMAGOTCHI_RECAP_TIMEOUT SAMAGOTCHI_RECAP_MIN_USER_TURNS SAMAGOTCHI_RECAP_SENTENCES
      ]
      original = recap_env_keys.each_with_object({}) { |k, h| h[k] = ENV[k] }
      recap_env_keys.each { |k| ENV.delete(k) }
      example.run
    ensure
      recap_env_keys.each do |k|
        value = original[k]
        value.nil? ? ENV.delete(k) : ENV[k] = value
      end
    end

    def write_recap_yaml(dir, body)
      config_dir = File.join(dir, "samagotchi")
      Dir.mkdir(config_dir)
      File.write(File.join(config_dir, "config.yml"), body)
      ENV["XDG_CONFIG_HOME"] = dir
    end

    it "returns false for a scalar `recap: false`" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        write_recap_yaml(dir, "recap: false\n")
        expect(described_class.recap_config).to be(false)
      end
    end

    it "returns false for `recap: {enabled: false}` even with env values" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        write_recap_yaml(dir, "recap:\n  enabled: false\n")
        ENV["SAMAGOTCHI_RECAP_BASE_URL"] = "http://x:1/v1"
        ENV["SAMAGOTCHI_RECAP_MODEL"] = "m"
        expect(described_class.recap_config).to be(false)
      end
    end

    it "returns nil when nothing recap-related is configured" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        ENV["XDG_CONFIG_HOME"] = dir
        expect(described_class.recap_config).to be_nil
      end
    end

    it "resolves env-only values through the registry" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        ENV["XDG_CONFIG_HOME"] = dir
        ENV["SAMAGOTCHI_RECAP_BASE_URL"] = "http://x:1/v1"
        ENV["SAMAGOTCHI_RECAP_MODEL"] = "m"
        rc = described_class.recap_config
        expect(rc).to be_a(Hash)
        expect(rc[:base_url]).to eq("http://x:1/v1")
        expect(rc[:model]).to eq("m")
      end
    end

    it "maps legacy `recap: {host:}` to host_ref from the file" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        write_recap_yaml(dir, "recap:\n  host: small-box\n  model: small\n")
        rc = described_class.recap_config
        expect(rc[:host_ref]).to eq("small-box")
        expect(rc[:model]).to eq("small")
      end
    end

    it "passes recap.sentences from the file along" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        write_recap_yaml(dir, "recap:\n  model: m\n  base_url: http://x:1/v1\n  sentences: 2-3\n")
        expect(described_class.recap_config[:sentences]).to eq("2-3")
      end
    end

    it "prefers env over file for the same key" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        write_recap_yaml(dir, "recap:\n  model: file-model\n")
        ENV["SAMAGOTCHI_RECAP_MODEL"] = "env-model"
        expect(described_class.recap_config[:model]).to eq("env-model")
      end
    end
  end
end
