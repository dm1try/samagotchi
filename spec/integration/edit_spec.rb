# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "samagotchi/agent"
require "tmpdir"

# Integration tests that verify the model correctly calls the edit tool
# to replace a small section of a file.
#
# Prerequisites:
#   - A llama.cpp server must be running (default: localhost:8080)
#   - LLAMA_INTEGRATION=1 environment variable must be set
#
# Run with:
#   LLAMA_INTEGRATION=1 bundle exec rspec spec/integration/edit_spec.rb
#
# Verbose output (shows raw LLM responses and tool calls):
#   LLAMA_INTEGRATION=1 bundle exec rspec spec/integration/edit_spec.rb -v
#
# Custom server:
#   LLAMA_HOST=myhost LLAMA_PORT=9090 LLAMA_INTEGRATION=1 bundle exec rspec spec/integration/edit_spec.rb -v
RSpec.describe "edit tool - file editing integration", :integration do
  let(:kernel) { Samagotchi::KernelLoop.new(verbose: verbose) }
  let(:verbose) { false }

  around(:each) do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  def run_with_prompt(prompt)
    messages = [
      { role: "system", content: Samagotchi::Agent::SYSTEM_ASSIST },
      { role: "user",   content: prompt }
    ]
    kernel.run(messages)
  end

  it "edits a single line in a file and reports success" do
    path = File.join(@tmpdir, "greeting.txt")
    File.write(path, "Hello world\nHow are you?\nGoodbye\n")

    result = run_with_prompt(
      "Use the edit tool to replace the text 'How are you?' with 'How do you do?' " \
      "in the file #{path}. The <old> block should be exactly 'How are you?' and " \
      "the <new> block should be 'How do you do?'."
    )

    expect(File.read(path)).to include("How do you do?")
    expect(File.read(path)).not_to include("How are you?")
  end

  it "leaves the rest of the file unchanged after an edit" do
    path = File.join(@tmpdir, "code.rb")
    File.write(path, "def greet\n  puts 'hello'\nend\n")

    run_with_prompt(
      "Use the edit tool to replace \"puts 'hello'\" with \"puts 'hi'\" " \
      "in the file #{path}."
    )

    content = File.read(path)
    expect(content).to include("def greet")
    expect(content).to include("puts 'hi'")
    expect(content).to include("end")
  end
end
