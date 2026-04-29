# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "samagotchi/agent"
require "tmpdir"
require "fileutils"

# Integration tests that verify the model correctly calls memory_write to
# save a memory entry to disk.
#
# Prerequisites:
#   - A llama.cpp server must be running (default: localhost:8080)
#   - LLAMA_INTEGRATION=1 environment variable must be set
#
# Run with:
#   LLAMA_INTEGRATION=1 bundle exec rspec spec/integration/memory_write_spec.rb
#
# Verbose output (shows raw LLM responses and tool calls):
#   LLAMA_INTEGRATION=1 bundle exec rspec spec/integration/memory_write_spec.rb -v
#
# Custom server:
#   LLAMA_HOST=myhost LLAMA_PORT=9090 LLAMA_INTEGRATION=1 bundle exec rspec spec/integration/memory_write_spec.rb -v
RSpec.describe "memory_write tool - writing a new memory integration", :integration do
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

  it "writes a new memory entry when instructed" do
    memory_name = "secret_plan"
    memory_content = "# The Secret Plan\nPhase 1: Evolution."
    prompt = "Please save a new memory called '#{memory_name}' with the following content: #{memory_content}"

    run_with_prompt(prompt)

    # Verify the file was actually created on disk
    expect(File.exist?(File.join(memories_dir, "#{memory_name}.md"))).to be true
    expect(File.read(File.join(memories_dir, "#{memory_name}.md"))).to eq(memory_content)
  end
end
