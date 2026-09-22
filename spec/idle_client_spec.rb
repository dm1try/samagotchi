# frozen_string_literal: true

require "samagotchi/idle_client"

RSpec.describe Samagotchi::IdleClient do
  let(:client) { described_class.new(model: "gemma4-small", base_url: "http://localhost:8080/v1") }

  # Stand-in for the gem's OpenAI provider whose `connection.post` we stub — the
  # real Connection (and thus Faraday/Net::HTTP) is never touched.
  def install_provider!(post_result:, url_captures: nil, body_captures: nil)
    provider = instance_double(RubyLLM::Providers::OpenAI)
    connection = instance_double("Connection")
    allow(provider).to receive(:api_base).and_return("http://localhost:8080/v1")
    allow(connection).to receive(:post) do |url, body|
      url_captures << url if url_captures
      body_captures << body if body_captures
      post_result
    end
    allow(provider).to receive(:connection).and_return(connection)
    allow(client).to receive(:gem_provider).and_return(provider)
  end

  def chat_body(content)
    double(body: JSON.generate("choices" => [{ "message" => { "content" => content } }]))
  end

  describe "#summarize" do
    it "returns the assistant prose, trimmed" do
      install_provider!(post_result: chat_body("  the recap text  "))
      expect(client.summarize("summarize this")).to eq("the recap text")
    end

    it "returns nil when the prompt is blank (nothing to summarize)" do
      expect(client.summarize("   ")).to be_nil
    end

    it "returns nil when the server returns empty content" do
      install_provider!(post_result: chat_body("   "))
      expect(client.summarize("summarize this")).to be_nil
    end

    it "raises SummarizeError when the HTTP boundary fails (isolated by the caller)" do
      provider = instance_double(RubyLLM::Providers::OpenAI)
      connection = instance_double("Connection")
      allow(provider).to receive(:api_base).and_return("http://localhost:8080/v1")
      allow(connection).to receive(:post).and_raise("connection refused")
      allow(provider).to receive(:connection).and_return(connection)
      allow(client).to receive(:gem_provider).and_return(provider)

      expect { client.summarize("hi") }
        .to raise_error(described_class::SummarizeError, /connection refused/)
    end

    it "raises SummarizeError when the response has no parseable message" do
      install_provider!(post_result: double(body: JSON.generate("choices" => [])))
      expect { client.summarize("hi") }.to raise_error(described_class::SummarizeError)
    end
  end

  describe "the OpenAI-compatible request" do
    it "POSTs to the /chat/completions endpoint (not /completions)" do
      urls = []
      install_provider!(post_result: chat_body("ok"), url_captures: urls)

      client.summarize("summarize this")

      expect(urls).to eq(["http://localhost:8080/v1/chat/completions"])
    end

    it "sends a zero-temperature user message with the configured model and bounded output" do
      bodies = []
      install_provider!(post_result: chat_body("ok"), body_captures: bodies)

      client.summarize("summarize this")

      body = bodies.first
      expect(body[:model]).to eq("gemma4-small")
      expect(body[:temperature]).to eq(0.0)
      expect(body[:max_tokens]).to eq(256)
      expect(body[:messages]).to eq([{ role: "user", content: "summarize this" }])
    end
  end

  describe "reasoning_content fallback" do
    it "returns reasoning_content when content is empty" do
      reasoning = "Here's a thinking process: the answer is 42"
      install_provider!(post_result: double(body: JSON.generate(
        "choices" => [{ "message" => { "content" => "", "reasoning_content" => reasoning } }]
      )))
      expect(client.summarize("summarize this")).to eq(reasoning)
    end

    it "prefers content over reasoning_content when both are present" do
      install_provider!(post_result: double(body: JSON.generate(
        "choices" => [{ "message" => { "content" => "direct answer", "reasoning_content" => "thinking..." } }]
      )))
      expect(client.summarize("summarize this")).to eq("direct answer")
    end

    it "raises SummarizeError when both content and reasoning_content are empty" do
      install_provider!(post_result: double(body: JSON.generate(
        "choices" => [{ "message" => { "content" => "", "reasoning_content" => "" } }]
      )))
      expect { client.summarize("summarize this") }
        .to raise_error(described_class::SummarizeError, /no parseable/)
    end
  end

  describe "dummy key for the local endpoint" do
    it "does not raise for a dummy API key (gem configured? passes on non-nil key)" do
      # build_config is private; exercise it indirectly through the stubbed
      # provider so the real RubyLLM::Configuration is never constructed.
      provider = instance_double(RubyLLM::Providers::OpenAI)
      connection = instance_double("Connection")
      allow(provider).to receive(:api_base).and_return("http://localhost:8080/v1")
      allow(connection).to receive(:post).and_return(double(body: '{"choices": [{"message": {"content": "ok"}}]}'))
      allow(provider).to receive(:connection).and_return(connection)
      allow(client).to receive(:gem_provider).and_return(provider)
      expect { client.summarize("hi") }.not_to raise_error
    end
  end

  describe "request budget" do
    it "uses its own timeout and never retries" do
      config = described_class.new(model: "m", base_url: "http://x/v1", timeout: 12.5).send(:build_config)
      expect(config.request_timeout).to eq(12.5)
      expect(config.max_retries).to eq(0)
    end

    it "defaults to a short timeout, not the chat's global one" do
      config = described_class.new(model: "m", base_url: "http://x/v1").send(:build_config)
      expect(config.request_timeout).to eq(described_class::DEFAULT_TIMEOUT_SECONDS)
    end
  end
end
