# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "samagotchi/terminal_ui"
require "samagotchi/model_profile"
require "tmpdir"
require "fileutils"

# Integration test that verifies literal control-token text can survive a
# tool-response round trip without breaking generation.
#
# Prerequisites:
#   - A llama.cpp server must be running (default: localhost:8080)
#   - LLAMA_INTEGRATION=1 environment variable must be set
#
# Run with:
#   LLAMA_INTEGRATION=1 bundle exec rspec spec/integration/literal_tokens_spec.rb
#
# Verbose output (shows raw LLM responses and tool calls):
#   LLAMA_INTEGRATION=1 bundle exec rspec spec/integration/literal_tokens_spec.rb -v
#
# Custom server:
#   LLAMA_HOST=myhost LLAMA_PORT=9090 LLAMA_INTEGRATION=1 bundle exec rspec spec/integration/literal_tokens_spec.rb -v
RSpec.describe "read tool - literal control token integration", :integration do
  let(:kernel) { Samagotchi::KernelLoop.new(verbose: verbose, profile: profile) }
  let(:verbose) { false }
  let(:profile) { Samagotchi::ModelProfile.from_env }

  around(:each) do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  def run_with_prompt(prompt)
    messages = [
      { role: "system", content: Samagotchi::Agent.system_prompt_for(profile, mode: :assist) },
      { role: "user", content: prompt }
    ]
    kernel.run(messages)
  end

  it "reads a file containing active control tokens and reports them literally" do
    path = File.join(@tmpdir, "literal_tokens.txt")
    tokens = (profile.stop_sequences + [profile.tool_response_open]).compact.uniq
    File.write(path, tokens.join("\n") + "\n")

    result = run_with_prompt(
      "Use the read tool to inspect #{path}. " \
      "Then answer with the exact token strings that appear in the file, one per line, preserving punctuation exactly."
    )

    tokens.each do |token|
      expect(result.output).to include(token)
    end
  end
end
