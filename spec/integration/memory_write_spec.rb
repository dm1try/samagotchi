# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "samagotchi/terminal_ui"
require "samagotchi/model_profile"
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
      { role: "system", content: Samagotchi::Engine.system_prompt_for(Samagotchi::ModelProfile.from_env, mode: :assist) },
      { role: "user",   content: prompt }
    ]
    kernel.run(messages)
  end

  it "writes a new memory entry when instructed" do
    memory_name = "secret_plan"
    memory_content = "# The Secret Plan\nPhase 1: Evolution."
    prompt = "Please save a new memory called '#{memory_name}' in the project scope with this content copied exactly as-is byte-for-byte (do not reformat, do not change heading level): #{memory_content}"

    run_with_prompt(prompt)

    # Verify the file was actually created on disk
    expect(File.exist?(File.join(project_memories_dir, "#{memory_name}.md"))).to be true
    actual_content = File.read(File.join(project_memories_dir, "#{memory_name}.md"))
    expect([memory_content, memory_content + "\n"]).to include(actual_content)
  end

  it "auto-writes a managed index line when a description is requested" do
    memory_name = "index_guarded_plan"
    memory_content = "# The Guarded Plan"
    prompt = "Please save a new memory called '#{memory_name}' in the project scope with this content: #{memory_content}, and give it a short description"

    run_with_prompt(prompt)

    expect(File.exist?(File.join(project_memories_dir, "#{memory_name}.md"))).to be true
    index_path = File.join(project_memories_dir, "index.md")
    expect(File.exist?(index_path)).to be true
    contents = File.read(index_path)
    # A managed line (name · scope · date · size) should have been recorded.
    expect(contents).to include("- **#{memory_name}**")
  end
end
