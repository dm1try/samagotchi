# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/llm/chat_loop"
require "samagotchi/model_profile"

# Live chat-loop integration test: the OpenAI chat adapter against the
# integration server's /v1/chat/completions (with tool support), whatever
# api: the fixture host has. How to run: docs/testing.md.
RSpec.describe "chat loop - live tool round trip", :integration do
  let(:model_name) { IntegrationServer.model }
  let(:base_url) { IntegrationServer.openai_base_url }
  let(:kernel) { Samagotchi::KernelLoop.new(model_name: model_name) }
  let(:backend) do
    Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: Samagotchi::LLM::OpenAIChat.new(base_url: base_url, host_name: "live"))
  end

  it "uses execute to return the current UTC date" do
    expected_date = Time.now.utc.strftime("%Y-%m-%d")
    messages = [
      {
        role: "system",
        content: Samagotchi::Engine.system_prompt_for(Samagotchi::ModelProfile.from_model_name(model_name))
      },
      {
        role: "user",
        content: "Use the execute tool to run exactly `date -u +%Y-%m-%d`, then report the date it returns."
      }
    ]

    result = backend.complete(messages: messages, max_iterations: 6, model_name: model_name)

    expect(result.text).to include(expected_date)
    expect(result.conversation).to include(
      a_hash_including(role: "tool_response", content: a_string_including("[execute]"))
    )
  end
end
