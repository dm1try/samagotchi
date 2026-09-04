# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/config_file"
require "samagotchi/model_profile"
require "samagotchi/client"

RSpec.describe Samagotchi::ConfigFile do
  around do |example|
    original_env = {
      "XDG_CONFIG_HOME" => ENV["XDG_CONFIG_HOME"],
      "SAMAGOTCHI_DEFAULT_MODEL" => ENV["SAMAGOTCHI_DEFAULT_MODEL"],
      "LLAMA_HOST" => ENV["LLAMA_HOST"],
      "LLAMA_PORT" => ENV["LLAMA_PORT"]
    }

    begin
      ENV.delete("XDG_CONFIG_HOME")
      ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
      ENV.delete("LLAMA_HOST")
      ENV.delete("LLAMA_PORT")
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

    it "falls back to ~/.config" do
      expect(described_class.global_path(env: {})).to eq(File.expand_path("~/.config/samagotchi/config.yml"))
    end
  end

  describe ".load_global_env!" do
    it "loads flat scalar values and leaves existing env untouched" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        config_dir = File.join(dir, "samagotchi")
        Dir.mkdir(config_dir)
        File.write(File.join(config_dir, "config.yml"), <<~YAML)
          SAMAGOTCHI_DEFAULT_MODEL: Qwen3-14B-Instruct
          LLAMA_HOST: 192.168.1.29
          LLAMA_PORT: 8081
        YAML

        ENV["XDG_CONFIG_HOME"] = dir
        ENV["LLAMA_PORT"] = "9090"

        expect(described_class.load_global_env!).to be(true)
        expect(Samagotchi::ModelProfile.from_env.name).to eq("qwen36")
        expect(ENV["SAMAGOTCHI_DEFAULT_MODEL"]).to eq("Qwen3-14B-Instruct")

        client = Samagotchi::Client.new
        expect(client.instance_variable_get(:@host)).to eq("192.168.1.29")
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
          SAMAGOTCHI_DEFAULT_INPUT: "Hey Chi, "
        YAML

        ENV["XDG_CONFIG_HOME"] = dir

        expect(described_class.load_global_env!).to be(true)
        expect(ENV["SAMAGOTCHI_DEFAULT_INPUT"]).to eq("Hey Chi, ")
      end
    end
  end
end
