# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "samagotchi/agent"
require "samagotchi/model_profile"
require "tmpdir"
require "fileutils"

# Integration tests that verify the model correctly calls memory_read to read
# a memory entry that already exists on disk.
#
# Prerequisites:
#   - A llama.cpp server must be running (default: localhost:8080)
#   - LLAMA_INTEGRATION=1 environment variable must be set
#
# Run with:
#   LLAMA_INTEGRATION=1 bundle exec rspec spec/integration/memory_spec.rb
#
# Verbose output (shows raw LLM responses and tool calls):
#   LLAMA_INTEGRATION=1 bundle exec rspec spec/integration/memory_spec.rb -v
#
# Custom server:
#   LLAMA_HOST=myhost LLAMA_PORT=9090 LLAMA_INTEGRATION=1 bundle exec rspec spec/integration/memory_spec.rb -v
RSpec.describe "memory_read tool - reading existing memory integration", :integration do
  let(:kernel) { Samagotchi::KernelLoop.new(verbose: verbose) }
  let(:verbose) { false }
  let(:project_memories_dir) { Dir.mktmpdir }
  let(:system_memories_dir) { Dir.mktmpdir }

  before do
    stub_const("Samagotchi::Tools::PROJECT_MEMORIES_DIR", project_memories_dir)
    stub_const("Samagotchi::Tools::SYSTEM_MEMORIES_DIR", system_memories_dir)
  end

  after do
    FileUtils.rm_rf(project_memories_dir)
    FileUtils.rm_rf(system_memories_dir)
  end

  def run_with_prompt(prompt)
    messages = [
      { role: "system", content: Samagotchi::Agent.system_prompt_for(Samagotchi::ModelProfile.from_env, mode: :assist) },
      { role: "user",   content: prompt }
    ]
    kernel.run(messages)
  end

  it "reads an existing memory entry and includes its content in the response" do
    File.write(File.join(project_memories_dir, "test.md"), "# Test Memory\nThis is important test data.")

    result = run_with_prompt("Please read the 'test' memory entry and tell me what it says.")

    expect(result).to include("test data")
  end
end
