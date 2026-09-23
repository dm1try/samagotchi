# frozen_string_literal: true

require "samagotchi/llm/backend"
require "samagotchi/engine"
require "samagotchi/session"

RSpec.describe Samagotchi::LLM::Factory do
  # The provider selection reads the real ENV["SAMAGOTCHI_BACKEND"], so save and
  # restore it around every example (including the Engine integration block below).
  around do |example|
    original = ENV["SAMAGOTCHI_BACKEND"]
    example.run
    if original.nil?
      ENV.delete("SAMAGOTCHI_BACKEND")
    else
      ENV["SAMAGOTCHI_BACKEND"] = original
    end
  end

  describe ".resolve_provider" do
    it "defaults to :native when the env var is unset" do
      ENV.delete("SAMAGOTCHI_BACKEND")
      expect(described_class.resolve_provider).to eq(:native)
    end

    it "treats a blank env var as the :native default" do
      ENV["SAMAGOTCHI_BACKEND"] = ""
      expect(described_class.resolve_provider).to eq(:native)
    end

    it "strips surrounding whitespace and honors the value" do
      ENV["SAMAGOTCHI_BACKEND"] = "  ruby_llm  "
      expect(described_class.resolve_provider).to eq(:ruby_llm)
    end

    it "falls back to :native when the env var is nil" do
      ENV["SAMAGOTCHI_BACKEND"] = nil
      expect(described_class.resolve_provider).to eq(:native)
    end

    it "prefers an explicit value over ENV and resolves it to a symbol" do
      ENV["SAMAGOTCHI_BACKEND"] = "ruby_llm"
      expect(described_class.resolve_provider("native")).to eq(:native)
      expect(described_class.resolve_provider("  ruby_llm  ")).to eq(:ruby_llm)
    end

    it "normalizes an explicit symbol value" do
      expect(described_class.resolve_provider(:native)).to eq(:native)
    end
  end

  describe ".factory routing" do
    it "returns a NativeBackend for :native" do
      backend = described_class.factory(provider: :native, model_name: "gemma4")
      expect(backend).to be_a(Samagotchi::LLM::NativeBackend)
    end

    it "routes :ruby_llm to RubyLLMBackend (existing assertion)" do
      backend = described_class.factory(provider: :ruby_llm, model_name: "x")
      expect(backend).to be_a(Samagotchi::LLM::RubyLLMBackend)
    end

    it "raises a descriptive ArgumentError for an unknown provider (existing)" do
      expect { described_class.factory(provider: :watson, model_name: "x") }
        .to raise_error(ArgumentError, /native.*ruby_llm|ruby_llm.*native/)
    end

    it "returns a NativeBackend when provider: nil and ENV is unset (the :native default)" do
      ENV.delete("SAMAGOTCHI_BACKEND")
      backend = described_class.factory(provider: nil, model_name: "gemma4")
      expect(backend).to be_a(Samagotchi::LLM::NativeBackend)
    end

    it "resolves a nil provider against SAMAGOTCHI_BACKEND (the Engine path)" do
      ENV["SAMAGOTCHI_BACKEND"] = "ruby_llm"
      backend = described_class.factory(provider: nil, model_name: "x")
      expect(backend).to be_a(Samagotchi::LLM::RubyLLMBackend)
    end

    it "returns a NativeBackend when a blank env var maps to :native default" do
      ENV["SAMAGOTCHI_BACKEND"] = ""
      backend = described_class.factory(provider: nil, model_name: "gemma4")
      expect(backend).to be_a(Samagotchi::LLM::NativeBackend)
    end
  end

  describe "Engine#initialize selects the resolved backend" do
    # Inject stubs so the Engine builds without a live client / KernelLoop.
    let(:client) { instance_double(Samagotchi::Client) }
    let(:kernel) { instance_double(Samagotchi::KernelLoop) }

    def build_engine(**overrides)
      Samagotchi::Engine.new(mode: :assist, client: client, kernel: kernel, **overrides)
    end

    it "builds a NativeBackend by default" do
      ENV.delete("SAMAGOTCHI_BACKEND")
      engine = build_engine(model_name: "Gemma-4B-it")
      expect(engine.backend).to be_a(Samagotchi::LLM::NativeBackend)
    end

    it "builds the ruby_llm backend when SAMAGOTCHI_BACKEND=ruby_llm" do
      ENV["SAMAGOTCHI_BACKEND"] = "ruby_llm"
      engine = build_engine(model_name: "Gemma-4B-it")
      expect(engine.instance_variable_get(:@backend)).to be_a(Samagotchi::LLM::RubyLLMBackend)
    end

    it "uses an explicit backend and the selected host endpoint" do
      ENV["SAMAGOTCHI_BACKEND"] = "native"
      registry = Samagotchi::HostRegistry.new(
        hosts_config: {
          "splash" => { name: "splash", host: "192.168.1.29", port: 8000, transport: nil }
        }
      )

      engine = build_engine(host_registry: registry, model_name: "Splash-Model", backend: :ruby_llm)
      backend = engine.instance_variable_get(:@backend)

      expect(backend).to be_a(Samagotchi::LLM::RubyLLMBackend)
      expect(backend.instance_variable_get(:@base_url)).to eq("http://192.168.1.29:8000/v1")
    end

    it "builds a NativeBackend for a blank backend selection" do
      ENV["SAMAGOTCHI_BACKEND"] = ""
      engine = build_engine(model_name: "Gemma-4B-it")
      expect(engine.backend).to be_a(Samagotchi::LLM::NativeBackend)
    end
  end
end
