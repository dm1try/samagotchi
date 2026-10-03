# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "samagotchi/terminal_ui"
require "samagotchi/model_profile"
require "tmpdir"
require "fileutils"

# Integration tests that verify the model correctly calls memory_read to read
# a memory entry that already exists on disk.
#
# Needs a live model server; how to run: docs/testing.md.
RSpec.describe "memory_read tool - reading existing memory integration", :integration do
  let(:kernel) { Samagotchi::KernelLoop.new }
  let(:project_memories_dir) { Dir.mktmpdir }
  let(:system_memories_dir) { Dir.mktmpdir }

  before do
    allow(Samagotchi::MemoryPaths).to receive(:project_dir).and_return(project_memories_dir)
    allow(Samagotchi::MemoryPaths).to receive(:system_dir).and_return(system_memories_dir)
  end

  after do
    FileUtils.rm_rf(project_memories_dir)
    FileUtils.rm_rf(system_memories_dir)
  end

  def run_with_prompt(prompt)
    messages = [
      { role: "system", content: Samagotchi::Engine.system_prompt_for(Samagotchi::ModelProfile.from_model_name(Samagotchi::ModelProfile.required_model_name)) },
      { role: "user",   content: prompt }
    ]
    kernel.run(messages)
  end

  it "reads an existing memory entry and includes its content in the response" do
    File.write(File.join(project_memories_dir, "test.md"), "# Test Memory\nThis is important test data.")

    result = run_with_prompt("Please read the 'test' memory entry and tell me what it says.")

    expect(result.output).to include("test data")
  end
end
