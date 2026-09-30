# frozen_string_literal: true

require "json"
require "samagotchi/engine"
require "samagotchi/llm/chat_loop"

# Byte-for-byte snapshots of what each model is told about its tools: the
# native base system prompt per profile (tool declarations + call hint + the
# fixed guidance around them) and the tools: array the chat loop
# sends. These pin the prompt while tool schemas and dispatch are refactored;
# a change here must be deliberate.
#
# Regenerate after an intended change with:
#   UPDATE_PROMPTS=1 bundle exec rspec spec/prompt_snapshot_spec.rb
RSpec.describe "Prompt snapshots" do
  def fixture_dir = File.expand_path("fixtures/prompt_snapshots", __dir__)

  def expect_snapshot(name, actual)
    path = File.join(fixture_dir, name)
    if ENV["UPDATE_PROMPTS"] == "1"
      FileUtils.mkdir_p(fixture_dir)
      File.write(path, actual)
    end
    expect(actual).to eq(File.read(path))
  end

  def engine(profile)
    Samagotchi::Engine.new(client: instance_double(Samagotchi::Client),
                           kernel: instance_double(Samagotchi::KernelLoop), profile: profile)
  end

  %w[gemma4 qwen36].each do |profile|
    it "keeps the #{profile} base system prompt" do
      expect_snapshot("#{profile}_system_prompt.txt", engine(profile).assist_system_prompt)
    end
  end

  it "keeps the chat path's tool definitions" do
    backend = Samagotchi::LLM::ChatLoop.new(kernel: instance_double(Samagotchi::KernelLoop))
    expect_snapshot("chat_tools.json", JSON.pretty_generate(backend.tool_definitions) + "\n")
  end
end
