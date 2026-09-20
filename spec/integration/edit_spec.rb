# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "samagotchi/terminal_ui"
require "tmpdir"

# Integration tests that verify the model correctly calls the edit tool
# to replace a small section of a file.
#
# Prerequisites:
#   - A llama.cpp server must be running (default: localhost:8080)
#   - SAMAGOTCHI_INTEGRATION=1 environment variable must be set
#
# Run with:
#   SAMAGOTCHI_INTEGRATION=1 bundle exec rspec spec/integration/edit_spec.rb
#
# Verbose output (shows raw LLM responses and tool calls):
#   SAMAGOTCHI_INTEGRATION=1 bundle exec rspec spec/integration/edit_spec.rb -v
#
# Custom server:
#   SAMAGOTCHI_SERVER_HOST=myhost SAMAGOTCHI_SERVER_PORT=9090 SAMAGOTCHI_INTEGRATION=1 bundle exec rspec spec/integration/edit_spec.rb -v
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
      { role: "system", content: Samagotchi::Engine.system_prompt_for(Samagotchi::ModelProfile.from_env) },
      { role: "user",   content: prompt }
    ]
    kernel.run(messages)
  end

  it "edits a single line in a file and reports success" do
    path = File.join(@tmpdir, "greeting.txt")
    File.write(path, "Hello world\nHow are you?\nGoodbye\n")

    run_with_prompt(
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
      "Use the edit tool to replace \"puts 'hello'\" with \"new_hello\" " \
      "in the file #{path}."
    )

    content = File.read(path)
    expect(content).to include("def greet")
    expect(content).to include("new_hello")
    expect(content).to include("end")
  end

  it "edits multiple lines in a file and reports success" do
    path = File.join(@tmpdir, "multiline.txt")
    content = "Line 1\nLine 2\nLine 3\nLine 4\n"
    File.write(path, content)

    run_with_prompt(
      "Use the edit tool to replace the lines\n" \
      "Line 2\n" \
      "Line 3\n" \
      "with\n" \
      "Line 2 (updated)\n" \
      "Line 3 (updated)\n" \
      "in the file #{path}. The <old> block must be exactly\n" \
      "'Line 2\nLine 3' and the <new> block must be\n" \
      "'Line 2 (updated)\nLine 3 (updated)'."
    )

    expected_content = "Line 1\nLine 2 (updated)\nLine 3 (updated)\nLine 4\n"
    actual_content = File.read(path)
    expect([expected_content, expected_content.chomp]).to include(actual_content)
  end

  it "uses range mode to replace only the selected lines" do
    path = File.join(@tmpdir, "ranged.txt")
    File.write(path, "alpha\nbeta\ngamma\ndelta\n")

    run_with_prompt(
      "Use the edit tool in range mode to replace lines 2 through 3 of #{path} " \
      "with two lines: 'BETA' and 'GAMMA' (each on its own line, with a trailing newline). " \
      "Pass start_line=2 and end_line=3 as parameters. Do not supply old_text."
    )

    lines = File.readlines(path)
    expect(lines[0]).to eq("alpha\n")
    expect(lines[1]).to eq("BETA\n")
    expect(lines[2]).to eq("GAMMA\n")
    expect(lines[3]).to eq("delta\n")
  end
end
