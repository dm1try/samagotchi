# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/llm/chat_loop"
require "samagotchi/model_profile"

# Live chat-loop integration test.
#
# Prerequisites:
#   - An OpenAI-compatible server with /v1/chat/completions and tool support
#   - The server must be reachable at SAMAGOTCHI_SERVER_HOST:SAMAGOTCHI_SERVER_PORT
#     (or SAMAGOTCHI_OPENAI_API_BASE)
#   - SAMAGOTCHI_DEFAULT_MODEL must name the served model
#   - SAMAGOTCHI_INTEGRATION=1 must be set
#
# Run against the local llama.cpp, for example:
#   SAMAGOTCHI_INTEGRATION=1 \
#   SAMAGOTCHI_SERVER_HOST=192.0.2.10 SAMAGOTCHI_SERVER_PORT=8081 \
#   SAMAGOTCHI_DEFAULT_MODEL=ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M \
#   bundle exec rspec spec/integration/chat_loop_spec.rb -fd < /dev/null
RSpec.describe "chat loop - live tool round trip", :integration do
  let(:model_name) { ENV.fetch("SAMAGOTCHI_DEFAULT_MODEL") }
  let(:base_url) do
    ENV.fetch("SAMAGOTCHI_OPENAI_API_BASE", "http://#{ENV.fetch("SAMAGOTCHI_SERVER_HOST", "localhost")}:#{ENV.fetch("SAMAGOTCHI_SERVER_PORT", "8080")}/v1")
  end
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
