# frozen_string_literal: true

require "samagotchi/context_window"

RSpec.describe Samagotchi::ContextWindow do
  let(:client) { double("client") }

  around do |example|
    original = ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"]
    ENV.delete("SAMAGOTCHI_CONTEXT_WINDOW_TOKENS")
    described_class.reset!
    example.run
  ensure
    ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"] = original
    described_class.reset!
  end

  def stub_config(value, origin)
    allow(Samagotchi::Config).to receive(:get_with_origin).with("context.window_tokens").and_return([value, origin])
  end

  it "takes the server's window over a configured one" do
    allow(client).to receive(:context_window).with(model: "m").and_return(128_000)
    stub_config(200_000, :file)

    expect(described_class.resolve(client: client, model: "m").to_h).to eq(tokens: 128_000, source: :server)
  end

  it "falls back to the config file when the server reports none" do
    allow(client).to receive(:context_window).and_return(nil)
    stub_config(200_000, :file)

    expect(described_class.resolve(client: client, model: "m").to_h).to eq(tokens: 200_000, source: :config)
  end

  it "labels a CLI override as config and the env var as env" do
    stub_config(64_000, :cli)
    expect(described_class.resolve.source).to eq(:config)

    stub_config(32_000, :env)
    expect(described_class.resolve.to_h).to eq(tokens: 32_000, source: :env)
  end

  it "reads the real env var through Config" do
    ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"] = "48000"

    expect(described_class.resolve.to_h).to eq(tokens: 48_000, source: :env)
  end

  it "defaults to 256k when nothing reports or configures a window" do
    stub_config(nil, :default)

    expect(described_class.resolve(client: client_without_probe = Object.new).to_h)
      .to eq(tokens: 256_000, source: :default)
    expect(client_without_probe).not_to respond_to(:context_window)
  end

  it "ignores a non-positive configured value" do
    stub_config(0, :file)

    expect(described_class.resolve.source).to eq(:default)
  end

  it "remembers the last server window for callers without a client" do
    stub_config(nil, :default)
    expect(described_class.current.source).to eq(:default)

    allow(client).to receive(:context_window).and_return(128_000)
    described_class.resolve(client: client, model: "m")

    expect(described_class.current.to_h).to eq(tokens: 128_000, source: :server)
  end
end

RSpec.describe Samagotchi::ContextWindow, ".resolve with a host's model list" do
  let(:adapter) { double("adapter", context_window: 131_072) }

  it "takes the window the model list gives when the server reports none" do
    expect(described_class.resolve(client: nil, adapter: adapter, model: "m"))
      .to have_attributes(tokens: 131_072, source: :model_list)
  end

  it "prefers the running server's window" do
    client = double("client", context_window: 128_000)

    expect(described_class.resolve(client: client, adapter: adapter, model: "m").tokens).to eq(128_000)
  end

  it "falls back to config and the default when the list has nothing" do
    expect(described_class.resolve(client: nil, adapter: double(context_window: nil), model: "m").source).to eq(:default)
  end
end
