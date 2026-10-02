# frozen_string_literal: true

require "samagotchi/model_profile"

RSpec.describe Samagotchi::ModelProfile do
  describe ".default" do
    it "returns the Gemma 4 profile by default" do
      profile = described_class.default
      expect(profile.name).to eq("gemma4")
      expect(profile.turn_start).to eq("<|turn>")
      expect(profile.turn_end).to eq("<end_of_turn>")
    end
  end

  describe ".gemma4" do
    it "returns Gemma 4 token configuration" do
      profile = described_class.gemma4
      expect(profile.name).to eq("gemma4")
      expect(profile.turn_start).to eq("<|turn>")
      expect(profile.turn_end).to eq("<end_of_turn>")
      expect(profile.tool_call_open).to eq("<|tool_call>")
      expect(profile.tool_call_close).to eq("<tool_call|>")
      expect(profile.tool_response_open).to eq("<|tool_response>")
      expect(profile.tool_response_close).to eq("<tool_response|>")
      expect(profile.stop_sequences).to eq(["<end_of_turn>", "<|tool_response>"])
    end

    it "uses no role prefixes and thinks in a channel" do
      profile = described_class.gemma4
      expect(profile.uses_role_prefixes?).to be false
      expect([profile.thought_channel_open, profile.thought_channel_close]).to eq(["<|channel>thought", "<channel|>"])
      expect(described_class.qwen36.thought_channel_open).to be_nil
    end
  end

  describe ".qwen36" do
    it "returns Qwen 3.6 token configuration" do
      profile = described_class.qwen36
      expect(profile.name).to eq("qwen36")
      expect(profile.turn_start).to eq("")
      expect(profile.turn_end).to eq("")
      expect(profile.tool_call_open).to eq("<tool_call>")
      expect(profile.tool_call_close).to eq("</tool_call>")
      expect(profile.tool_response_open).to eq("<tool_response>")
      expect(profile.tool_response_close).to eq("</tool_response>")
      expect(profile.stop_sequences).to eq(["<|im_end|>"])
    end

    it "uses role prefixes and simple think tags" do
      profile = described_class.qwen36
      expect(profile.uses_role_prefixes?).to be true
      expect(profile.thought_open).to eq("<think>")
      expect(profile.thought_close).to eq("</think>")
    end

    it "has correct role prefixes" do
      profile = described_class.qwen36
      expect(profile.system_prefix).to eq("<|im_start|>system\n")
      expect(profile.user_prefix).to eq("<|im_start|>user\n")
      expect(profile.assistant_prefix).to eq("<|im_start|>assistant\n")
    end
  end

  describe ".from_model_name" do
    it "infers Qwen profile when model name contains qwen" do
      profile = described_class.from_model_name("Qwen3-14B-Instruct")
      expect(profile.name).to eq("qwen36")
    end

    it "infers Gemma profile when model name contains gemma" do
      expect(described_class.from_model_name("gemma-4-31B-it").name).to eq("gemma4")
    end

    # Many models with other names are Qwen-based (Ornith, ISTA-DASLab...).
    it "falls back to the Qwen profile for model names that say neither family" do
      expect(described_class.from_model_name("ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M").name).to eq("qwen36")
      expect(described_class.from_model_name("some-other-model").name).to eq("qwen36")
    end
  end

  describe ".required_model_name" do
    around do |example|
      original = ENV.fetch("SAMAGOTCHI_DEFAULT_MODEL", nil)
      original_xdg = ENV["XDG_CONFIG_HOME"]
      Dir.mktmpdir("samagotchi-empty") do |dir|
        ENV["XDG_CONFIG_HOME"] = dir
        # Clear Config cache so file isolation takes effect
        Samagotchi::Config.reload!(cli_overrides: {}) rescue nil
        example.run
      ensure
        if original.nil?
          ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
        else
          ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
        end
        ENV["XDG_CONFIG_HOME"] = original_xdg
        Samagotchi::Config.reload!(cli_overrides: {}) rescue nil
      end
    end

    it "raises when model is missing" do
      ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
      expect { described_class.check_host!(described_class.required_model_name) }
        .to raise_error(ArgumentError, /no model configured: set default.model in .*config.yml/)
    end

    it "returns explicit argument when provided" do
      ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
      expect(described_class.required_model_name("Qwen3-14B-Instruct")).to eq("Qwen3-14B-Instruct")
    end

    it "returns environment model when argument is blank" do
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
      expect(described_class.required_model_name(" ")).to eq("Gemma-4B-it")
    end

    context "with a host prefix that names no configured host (.check_host!)" do
      def write_config(text)
        path = File.join(ENV["XDG_CONFIG_HOME"], "samagotchi", "config.yml")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, text)
        Samagotchi::Config.reload!(cli_overrides: {}) rescue nil
      end

      before do
        ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
        write_config(<<~YAML)
          hosts:
            main: {host: localhost, port: 8080}
            openrouter: {url: "https://openrouter.ai/api/v1", api: openai}
          model_aliases:
            gone: oprnrouter:anthropic/claude-sonnet-4
        YAML
      end

      it "raises naming the unknown host and the configured ones, with a did-you-mean" do
        expect { described_class.check_host!("openruter:anthropic/claude-sonnet-4") }
          .to raise_error(described_class::MissingModel,
                          "unknown host 'openruter' in model 'openruter:anthropic/claude-sonnet-4' " \
                          "(did you mean 'openrouter'?); the configured hosts are main, openrouter")
      end

      it "checks what an alias points to" do
        expect { described_class.check_host!("gone") }
          .to raise_error(described_class::MissingModel, /unknown host 'oprnrouter' in model 'oprnrouter:anthropic/)
      end

      it "checks default.model from config.yml" do
        write_config(<<~YAML)
          default:
            model: nosuch:org/model
          hosts:
            main: {host: localhost, port: 8080}
        YAML
        expect { described_class.check_host!(described_class.required_model_name) }
          .to raise_error(described_class::MissingModel,
                          "unknown host 'nosuch' in model 'nosuch:org/model'; the configured hosts are main")
      end

      it "keeps model ids whose ':' is a tag, not a host" do
        %w[qwen3:8b mistral:7b deepseek-r1:8b nosuch:x unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M openai/gpt-4o:free
           hf.co/org/repo:Q4_K_M main:org/model openrouter:anthropic/claude-sonnet-4 openrouter:x
           openrouter/anthropic/claude].each do |id|
          expect(described_class.check_host!(id)).to eq(id)
        end
      end

      it "refuses a well-known provider's name as a prefix even without an org/model id" do
        expect { described_class.check_host!("openai:gpt-4o") }
          .to raise_error(described_class::UnknownHost,
                          "unknown host 'openai' in model 'openai:gpt-4o'; the configured hosts are main, openrouter")
        expect { described_class.check_host!("Anthropic:claude-sonnet-4", hosts: { "main" => {} }) }
          .to raise_error(described_class::UnknownHost, /unknown host 'anthropic'/)
        expect { described_class.check_host!("openrouter:x", hosts: { "main" => {} }) }
          .to raise_error(described_class::UnknownHost, /unknown host 'openrouter'.*the configured hosts are main\z/)
      end

      it "refuses a disabled host's prefix instead of sending the whole ref to the default host" do
        write_config(<<~YAML)
          hosts:
            main: {host: localhost, port: 8080}
            box: {host: box.local, port: 8080, enabled: false}
          model_aliases:
            boxed: box:gemma
        YAML
        %w[box:gemma Box:gemma box:org/model boxed].each do |name|
          expect { described_class.check_host!(name) }
            .to raise_error(described_class::UnknownHost, "host 'box' is disabled (enabled: false in config.yml)")
        end
        expect(described_class.check_host!("qwen3:8b")).to eq("qwen3:8b")
        expect(described_class.check_host!("main:gemma")).to eq("main:gemma")
      end

      it "reads enabled: as a \"false\" string and the host name in any case" do
        write_config(<<~YAML)
          hosts:
            main: {host: localhost, port: 8080}
            BOX: {host: box.local, port: 8080, enabled: " False "}
            spare: {host: spare.local, port: 8080, enabled: "no"}
        YAML
        expect { described_class.check_host!("box:org/model") }
          .to raise_error(described_class::UnknownHost, "host 'box' is disabled (enabled: false in config.yml)")
        expect(described_class.check_host!("spare:org/model")).to eq("spare:org/model")
      end

      it "refuses a disabled host in a worker, whose hosts come from SAMAGOTCHI_HOSTS_JSON" do
        write_config(<<~YAML)
          hosts:
            main: {host: localhost, port: 8080}
            box: {host: box.local, port: 8080, enabled: false}
        YAML
        json = Samagotchi::ConfigFile.hosts_json_for_env(env: ENV)
        worker_env = ENV.to_h.merge("SAMAGOTCHI_HOSTS_JSON" => json)
        expect { described_class.check_host!("box:gemma", env: worker_env) }
          .to raise_error(described_class::UnknownHost, "host 'box' is disabled (enabled: false in config.yml)")
      end

      it "takes a disabled host that the hosts given include as enabled" do
        write_config(<<~YAML)
          hosts:
            box: {host: box.local, port: 8080, enabled: false}
        YAML
        expect(described_class.check_host!("box:gemma", hosts: { "box" => {} })).to eq("box:gemma")
      end

      it "checks against the hosts it is given (a HostRegistry's entries)" do
        expect(described_class.check_host!("alpha:org/model", hosts: { "alpha" => {} })).to eq("alpha:org/model")
        expect { described_class.check_host!("main:org/model", hosts: { "alpha" => {} }) }
          .to raise_error(described_class::UnknownHost, /unknown host 'main'.*the configured hosts are alpha/)
      end
    end
  end

  describe ".from_model_name of the configured model" do
    around do |example|
      original = ENV.fetch("SAMAGOTCHI_DEFAULT_MODEL", nil)
      example.run
    ensure
      if original.nil?
        ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
      else
        ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
      end
    end

    it "infers qwen36 from SAMAGOTCHI_DEFAULT_MODEL" do
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Qwen3-14B-Instruct"
      profile = described_class.from_model_name(described_class.required_model_name)
      expect(profile.name).to eq("qwen36")
    end

    it "infers gemma4 from a gemma SAMAGOTCHI_DEFAULT_MODEL" do
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
      profile = described_class.from_model_name(described_class.required_model_name)
      expect(profile.name).to eq("gemma4")
    end
  end
end
