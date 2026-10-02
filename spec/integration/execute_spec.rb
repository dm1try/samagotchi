# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "samagotchi/terminal_ui"
require "samagotchi/model_profile"

# Integration tests that verify the model correctly calls the execute tool
# and returns the output of Ruby expressions.
#
# Prerequisites:
#   - A llama.cpp server must be running (default: localhost:8080)
#   - SAMAGOTCHI_INTEGRATION=1 environment variable must be set
#
# Run with:
#   SAMAGOTCHI_INTEGRATION=1 bundle exec rspec spec/integration/execute_spec.rb
#
# Verbose output (shows raw LLM responses and tool calls):
#   SAMAGOTCHI_INTEGRATION=1 bundle exec rspec spec/integration/execute_spec.rb -v
#
# Custom server:
#   SAMAGOTCHI_SERVER_HOST=myhost SAMAGOTCHI_SERVER_PORT=9090 SAMAGOTCHI_INTEGRATION=1 bundle exec rspec spec/integration/execute_spec.rb -v
RSpec.describe "execute tool - ruby expression integration", :integration do
  let(:kernel) { Samagotchi::KernelLoop.new }

  def run_with_prompt(prompt)
    messages = [
      { role: "system", content: Samagotchi::Engine.system_prompt_for(Samagotchi::ModelProfile.from_model_name(Samagotchi::ModelProfile.required_model_name)) },
      { role: "user",   content: prompt }
    ]
    kernel.run(messages)
  end

  describe "arithmetic" do
    it "evaluates 2 + 2 and returns 4" do
      result = run_with_prompt("Use the execute tool to run: ruby -e 'puts 2 + 2'")
      expect(result.output).to include("4")
    end

    it "evaluates an array sum and returns 6" do
      result = run_with_prompt("Use the execute tool to run: ruby -e 'puts [1, 2, 3].sum'")
      expect(result.output).to include("6")
    end
  end

  describe "string output" do
    it "outputs 'hello world'" do
      result = run_with_prompt("Use the execute tool to run: ruby -e 'puts \"hello world\"'")
      expect(result.output).to include("hello world")
    end
  end
end
