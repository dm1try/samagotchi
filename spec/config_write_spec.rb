# frozen_string_literal: true

require "tmpdir"
require "yaml"
require "spec_helper"
require "samagotchi/config"

# /model --default and /model --alias write one key into config.yml; the
# rest of the file, comments included, stays as the user wrote it.
RSpec.describe Samagotchi::ConfigFile, "writes to config.yml" do
  around do |example|
    Dir.mktmpdir("chi-config-write") do |dir|
      @path = File.join(dir, "config.yml")
      example.run
    end
  end

  let(:commented) do
    <<~YAML
      # my chi config
      default:
        # the model I use most
        model: old-model   # was gemma
        thinking: high
      model_aliases:
        small: gemma-small   # quick one
      # hosts below
      hosts:
        box:
          host: 192.168.1.5
    YAML
  end

  def write_config(text)
    File.write(@path, text)
    described_class.clear_yaml_cache!(@path)
  end

  def data = YAML.safe_load_file(@path)

  describe ".write_default_model!" do
    it "replaces default.model in place and keeps the comments" do
      write_config(commented)

      described_class.write_default_model!("box:qwen", path: @path)

      expect(File.read(@path)).to eq(commented.sub("  model: old-model   # was gemma", '  model: "box:qwen"'))
      expect(data.dig("default", "model")).to eq("box:qwen")
    end

    it "adds model under an existing default: without one" do
      write_config("# top\ndefault:\n  thinking: high\n# end\n")

      described_class.write_default_model!("qwen", path: @path)

      expect(File.read(@path)).to eq("# top\ndefault:\n  thinking: high\n  model: \"qwen\"\n# end\n")
    end

    it "appends a default: section when the file has none" do
      write_config("# only hosts\nhosts:\n  box:\n    host: a\n")

      described_class.write_default_model!("qwen", path: @path)

      expect(File.read(@path)).to start_with("# only hosts\nhosts:\n")
      expect(data).to eq("hosts" => { "box" => { "host" => "a" } }, "default" => { "model" => "qwen" })
    end

    it "writes a new file" do
      described_class.write_default_model!("qwen", path: @path)

      expect(data).to eq("default" => { "model" => "qwen" })
    end

    it "falls back to a whole rewrite for a flow-style section" do
      write_config("# gone\ndefault: {model: a, thinking: high}\n")

      described_class.write_default_model!("b", path: @path)

      expect(data).to eq("default" => { "model" => "b", "thinking" => "high" })
    end

    it "never writes a section twice" do
      write_config("default: {model: a}\n")

      described_class.write_default_model!("b", path: @path)

      expect(File.read(@path).scan(/^default:/).length).to eq(1)
      expect(data).to eq("default" => { "model" => "b" })
    end
  end

  describe ".write_model_alias!" do
    it "adds an alias and keeps the comments" do
      write_config(commented)

      previous = described_class.write_model_alias!("big", "box:qwen-32b", path: @path)

      expect(previous).to be_nil
      expect(File.read(@path)).to include("# my chi config", "  small: gemma-small   # quick one", "# hosts below")
      expect(data["model_aliases"]).to eq("small" => "gemma-small", "big" => "box:qwen-32b")
    end

    it "replaces an alias written in another case and returns its old target" do
      write_config(commented.sub("small:", "Small:"))

      previous = described_class.write_model_alias!("small", "gemma-tiny", path: @path)

      expect(previous).to eq("gemma-small")
      expect(File.read(@path)).to include("# hosts below")
      expect(data["model_aliases"]).to eq("small" => "gemma-tiny")
    end

    it "refuses a reserved name" do
      expect { described_class.write_model_alias!("default", "x", path: @path) }
        .to raise_error(ArgumentError, /reserved/)
    end
  end
end
