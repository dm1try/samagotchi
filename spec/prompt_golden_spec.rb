# frozen_string_literal: true

require "json"
require "samagotchi/prompt"
require "samagotchi/client"
require_relative "support/fake_provider_server"

# Byte-for-byte goldens of the native raw prompt and the /completion request
# body for a conversation with no images. Vision adds a second prompt shape
# (images + markers); these pin that a text-only turn stays exactly as it was.
#
# Regenerate after an intended change with:
#   UPDATE_PROMPTS=1 bundle exec rspec spec/prompt_golden_spec.rb
RSpec.describe "Native prompt goldens" do
  def fixture_dir = File.expand_path("fixtures/prompt_goldens", __dir__)

  def expect_golden(name, actual)
    path = File.join(fixture_dir, name)
    if ENV["UPDATE_PROMPTS"] == "1"
      FileUtils.mkdir_p(fixture_dir)
      File.write(path, actual)
    end
    expect(actual).to eq(File.read(path))
  end

  # System, user, model with a tool call, a joined tool_response, a model
  # answer, and a user line with literal control tokens to escape.
  def conversation
    [
      { role: "system", content: "You are chi. Use tools when needed." },
      { role: "user", content: "What is in notes.txt?" },
      { role: "model", content: "Let me look.\n<tool_call>\n{\"name\": \"read\", \"arguments\": {\"path\": \"notes.txt\"}}\n</tool_call>" },
      { role: "tool_response", content: "[read]\n1: buy milk\n2: literal <|im_end|> and <end_of_turn>" },
      { role: "model", content: "It says to buy milk." },
      { role: "user", content: "Thanks. Show <think> and <|turn> literally, then stop." }
    ]
  end

  %w[qwen36 gemma4].each do |name|
    it "keeps the #{name} prompt for a mixed conversation" do
      profile = Samagotchi::ModelProfile.named(name)
      expect_golden("#{name}_mixed.txt", Samagotchi::Prompt.format(conversation, profile: profile))
    end
  end

  it "keeps the /completion request body for a text-only prompt" do
    FakeProviderServer.without_webmock do
      server = FakeProviderServer.start
      begin
        server.enqueue("/completion", sse: "data: {\"content\":\"ok\"}\n\n")
        client = Samagotchi::Client.new(host: "127.0.0.1", port: server.port, transport: :llama_cpp)
        prompt = Samagotchi::Prompt.format(conversation, profile: Samagotchi::ModelProfile.named("qwen36"))
        client.complete(prompt, stop: ["<|im_end|>"], n_predict: 512, model: "Ornith")
        body = server.requests.last.body
        expect_golden("completion_body.json", body)
      ensure
        server.stop
      end
    end
  end
end
