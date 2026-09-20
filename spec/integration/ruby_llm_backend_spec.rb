# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/llm/ruby_llm_backend"
require "samagotchi/model_profile"

# Live RubyLLM backend integration test.
#
# Prerequisites:
#   - An OpenAI-compatible server with /v1/chat/completions and tool support
#   - The server must be reachable at SAMAGOTCHI_SERVER_HOST:SAMAGOTCHI_SERVER_PORT
#   - SAMAGOTCHI_DEFAULT_MODEL must name the served model
#   - SAMAGOTCHI_INTEGRATION=1 must be set
#
# Run against Splash, for example:
#   SAMAGOTCHI_INTEGRATION=1 \
#   SAMAGOTCHI_SERVER_HOST=192.168.1.29 SAMAGOTCHI_SERVER_PORT=8000 \
#   SAMAGOTCHI_DEFAULT_MODEL=incoai/Qwen3.8-27B-Splash \
#   bundle exec rspec spec/integration/ruby_llm_backend_spec.rb -fd < /dev/null
RSpec.describe "ruby_llm backend - live tool round trip", :integration do
  let(:model_name) { ENV.fetch("SAMAGOTCHI_DEFAULT_MODEL") }
  let(:base_url) do
    ENV.fetch("SAMAGOTCHI_OPENAI_API_BASE", "http://#{ENV.fetch("SAMAGOTCHI_SERVER_HOST", "localhost")}:#{ENV.fetch("SAMAGOTCHI_SERVER_PORT", "8080")}/v1")
  end
  let(:kernel) { Samagotchi::KernelLoop.new(model_name: model_name) }
  let(:backend) do
    Samagotchi::LLM::RubyLLMBackend.new(
      model_name: model_name,
      kernel: kernel,
      base_url: base_url
    )
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

    result = backend.complete(messages: messages, max_iterations: 6)

    expect(result.text).to include(expected_date)
    expect(result.conversation).to include(
      a_hash_including(role: "tool_response", content: a_string_including("[execute]"))
    )
  end
end
