# frozen_string_literal: true

require "spec_helper"
require "samagotchi/idle_client"
require "samagotchi/cancellation_controller"
require_relative "support/fake_provider_server"

RSpec.describe Samagotchi::IdleClient do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start }
  let(:client) { described_class.new(model: "gemma-small", base_url: server.base_url) }

  after { server.stop }

  def reply(message = nil, finish_reason: "stop", **fields)
    message ||= fields
    server.enqueue("/v1/chat/completions", json: { choices: [{ message: message, finish_reason: finish_reason }] })
  end

  def request_body = server.requests.last.json

  describe "#summarize" do
    it "returns the assistant prose, trimmed" do
      reply(content: "  the recap text  ")
      expect(client.summarize("summarize this").text).to eq("the recap text")
    end

    it "names the model that answered, as the server reports it" do
      server.enqueue("/v1/chat/completions", json: { model: "served/model-Q4.gguf",
                                                     choices: [{ message: { content: "Recap." }, finish_reason: "stop" }] })
      summary = client.summarize("summarize this")
      expect(summary).to have_attributes(text: "Recap.", model: "served/model-Q4.gguf")
      expect(summary.to_s).to eq("Recap.")
    end

    it "has no served model when the server names none" do
      reply(content: "Recap.")
      expect(client.summarize("summarize this").model).to be_nil
    end

    it "sends a message list as given (a system + user recap prompt)" do
      reply(content: "ok")
      client.summarize([{ role: "system", content: "Recap only." }, { role: "user", content: "the chat" }])
      expect(request_body["messages"]).to eq([{ "role" => "system", "content" => "Recap only." },
                                              { "role" => "user", "content" => "the chat" }])
    end

    it "returns nil when the prompt is blank (nothing to summarize)" do
      expect(client.summarize("   ")).to be_nil
      expect(server.requests).to be_empty
    end

    it "returns nil when the server returns empty content" do
      reply(content: "   ")
      expect(client.summarize("summarize this")).to be_nil
    end

    it "raises SummarizeError when the server can't be reached (isolated by the caller)" do
      dead = described_class.new(model: "m", base_url: "http://127.0.0.1:#{server.port}/v1")
      server.stop

      expect { dead.summarize("hi") }.to raise_error(described_class::SummarizeError, /recap summarization failed/)
    end

    it "raises SummarizeError for an error status, once (a recap never retries)" do
      server.default("/v1/chat/completions", status: 503, json: { error: { message: "busy" } })

      expect { client.summarize("hi") }.to raise_error(described_class::SummarizeError, /busy/)
      expect(server.requests.size).to eq(1)
    end

    it "raises SummarizeError when the response has no parseable message" do
      server.enqueue("/v1/chat/completions", json: { choices: [] })
      expect { client.summarize("hi") }.to raise_error(described_class::SummarizeError)
    end
  end

  describe "the OpenAI-compatible request" do
    it "POSTs one plain (not streamed) request to /chat/completions" do
      reply(content: "ok")

      client.summarize("summarize this")

      expect(server.requests.last.path).to eq("/v1/chat/completions")
      expect(request_body["stream"]).to be(false)
    end

    it "sends a zero-temperature user message with the configured model, bounded output and no tools" do
      reply(content: "ok")

      client.summarize("summarize this")

      expect(request_body).to include("model" => "gemma-small", "temperature" => 0.0, "max_tokens" => 512,
                                      "messages" => [{ "role" => "user", "content" => "summarize this" }])
      expect(request_body).not_to include("tools")
    end

    # A reasoning model spent a 256-token budget on thinking and the recap
    # stopped mid-sentence. Templates without the switch ignore it.
    it "asks the chat template to skip thinking" do
      reply(content: "ok")

      client.summarize("summarize this")

      expect(request_body["chat_template_kwargs"]).to eq("enable_thinking" => false)
    end

    # Splash ignores enable_thinking and thought until max_tokens; the
    # OpenAI-style knob turns it off there.
    it "asks for no reasoning effort" do
      reply(content: "ok")

      client.summarize("summarize this")

      expect(request_body["reasoning_effort"]).to eq("none")
    end

    # gpt-oss on OpenRouter: HTTP 400 "Reasoning is mandatory" for any off
    # form. The recap asks again without the fields, and stops sending them.
    it "asks again without the thinking fields when the host refuses them, and leaves them out after" do
      server.enqueue("/v1/chat/completions", status: 400,
                                             json: { error: { message: "Reasoning is mandatory for this endpoint and cannot be disabled." } })
      reply(content: "the recap.")
      reply(content: "again.")

      expect(client.summarize("summarize this").text).to eq("the recap.")
      expect(client.summarize("summarize that").text).to eq("again.")

      bodies = server.requests.map(&:json)
      expect(bodies.map { |b| b.key?("reasoning_effort") }).to eq([true, false, false])
      expect(bodies.map { |b| b.key?("chat_template_kwargs") }).to eq([true, false, false])
    end

    it "doesn't ask again for a 400 about something else" do
      server.enqueue("/v1/chat/completions", status: 400, json: { error: { message: "bad temperature" } })

      expect { client.summarize("summarize this") }.to raise_error(described_class::SummarizeError)
      expect(server.requests.size).to eq(1)
    end

    it "sends the key of a host that needs one, and no header otherwise" do
      keyed = described_class.new(model: "m", base_url: server.base_url, api_key_env: "RECAP_KEY",
                                  env: { "RECAP_KEY" => "sk-recap" })
      reply(content: "ok")
      reply(content: "ok")

      keyed.summarize("hi")
      expect(server.requests.last.header("authorization")).to eq("Bearer sk-recap")
      client.summarize("hi")
      expect(server.requests.last.header("authorization")).to be_nil
    end
  end

  describe "a reply cut off by max_tokens" do
    it "keeps the full sentences" do
      reply({ content: "The goal was a flag. It is done! This is" }, finish_reason: "length")
      expect(client.summarize("summarize this").text).to eq("The goal was a flag. It is done!")
    end

    it "gives no recap when not even one sentence finished" do
      reply({ content: "The goal was to add a" }, finish_reason: "length")
      expect(client.summarize("summarize this")).to be_nil
    end

    it "leaves a finished reply alone" do
      reply(content: "Done. No trailing stop")
      expect(client.summarize("summarize this").text).to eq("Done. No trailing stop")
    end
  end

  describe "reasoning_content fallback" do
    it "returns reasoning_content when content is empty" do
      reasoning = "Here's a thinking process: the answer is 42"
      reply(content: "", reasoning_content: reasoning)
      expect(client.summarize("summarize this").text).to eq(reasoning)
    end

    # A server that ignored the thinking switch thought until max_tokens:
    # its finished sentences are thinking, never a recap.
    it "gives no recap when the reasoning was cut off by max_tokens" do
      reasoning = "Here's a thinking process: 1. Analyze the input. It is a chat. 2. Draft the"
      reply({ content: "", reasoning_content: reasoning }, finish_reason: "length")
      expect(client.summarize("summarize this")).to be_nil
    end

    it "prefers content over reasoning_content when both are present" do
      reply(content: "direct answer", reasoning_content: "thinking...")
      expect(client.summarize("summarize this").text).to eq("direct answer")
    end

    it "raises SummarizeError when both content and reasoning_content are empty" do
      reply(content: "", reasoning_content: "")
      expect { client.summarize("summarize this") }
        .to raise_error(described_class::SummarizeError, /no parseable/)
    end
  end

  describe "request budget" do
    it "uses its own timeout, one attempt, no stream" do
      expect(Samagotchi::LLM::OpenAIChat).to receive(:new)
        .with(hash_including(timeout: 12.5, retries: false, stream: false)).and_call_original
      described_class.new(model: "m", base_url: "http://x/v1", timeout: 12.5)
    end

    it "defaults to a short timeout, not the chat's global one" do
      expect(Samagotchi::LLM::OpenAIChat).to receive(:new)
        .with(hash_including(timeout: described_class::DEFAULT_TIMEOUT_SECONDS)).and_call_original
      described_class.new(model: "m", base_url: "http://x/v1")
    end
  end

  describe "#ask" do
    it "sends the messages as given with the limit, no tools and thinking off" do
      reply(content: " The answer. ")
      answer = client.ask([{ role: "system", content: "brief" }, { role: "user", content: "q?" }], max_tokens: 300)

      expect(answer.text).to eq("The answer.")
      expect(request_body).to include("max_tokens" => 300, "reasoning_effort" => "none",
                                      "chat_template_kwargs" => { "enable_thinking" => false })
      expect(request_body["messages"].last).to eq("role" => "user", "content" => "q?")
      expect(request_body["tools"]).to be_nil.or eq([])
    end

    it "keeps an answer cut off by the limit, marked with …" do
      reply(content: "It started to say something and", finish_reason: "length")
      expect(client.ask([{ role: "user", content: "q" }]).text).to eq("It started to say something and…")
    end

    it "raises RequestCancelled for a cancelled controller, and sends nothing" do
      controller = Samagotchi::CancellationController.new
      controller.cancel!(:manual)
      expect { client.ask([{ role: "user", content: "q" }], cancel_controller: controller) }
        .to raise_error(Samagotchi::LLM::RequestCancelled)
      expect(server.requests).to be_empty
    end

    it "raises SummarizeError when the server can't be reached" do
      dead = described_class.new(model: "m", base_url: "http://127.0.0.1:#{server.port}/v1")
      server.stop
      expect { dead.ask([{ role: "user", content: "q" }]) }.to raise_error(described_class::SummarizeError)
    end
  end
end
