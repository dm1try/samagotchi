# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "samagotchi/agent"
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
  let(:memories_dir) { Dir.mktmpdir }

  before { stub_const("Samagotchi::Tools::MEMORIES_DIR", memories_dir) }
  after  { FileUtils.rm_rf(memories_dir) }

  def run_with_prompt(prompt)
    messages = [
      { role: "system", content: Samagotchi::Agent::SYSTEM_ASSIST },
      { role: "user",   content: prompt }
    ]
    kernel.run(messages)
  end

  it "reads an existing memory entry and includes its content in the response" do
    File.write(File.join(memories_dir, "test.md"), "# Test Memory\nThis is important test data.")

    result = run_with_prompt("Please read the 'test' memory entry and tell me what it says.")

    expect(result).to include("test data")
  end
end
