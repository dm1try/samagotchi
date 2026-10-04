# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "samagotchi/terminal_ui"
require "samagotchi/model_profile"
require "tmpdir"
require "fileutils"

# Integration test that verifies literal control-token text can survive a
# tool-response round trip without breaking generation.
#
# Needs a live model server; how to run: docs/testing.md.
RSpec.describe "read tool - literal control token integration", :integration do
  let(:kernel) { Samagotchi::KernelLoop.new(profile: profile) }
  let(:profile) { Samagotchi::ModelProfile.from_model_name(Samagotchi::ModelProfile.required_model_name) }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  def run_with_prompt(prompt)
    messages = [
      { role: "system", content: Samagotchi::Engine.system_prompt_for(profile) },
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
