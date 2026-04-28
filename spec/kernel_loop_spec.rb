# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "fileutils"

RSpec.describe Samagotchi::KernelLoop do
  # Minimal stand-in for Samagotchi::Client
  let(:client) { instance_double(Samagotchi::Client) }
  subject(:kernel) { described_class.new(client: client) }

  describe "#run" do
    it "returns the model response when no tool calls are present" do
      allow(client).to receive(:complete).and_return("Hello!")
      expect(kernel.run([{ role: "user", content: "hi" }])).to eq("Hello!")
    end

    it "dispatches an execute tool call and includes result in follow-up prompt" do
      responses = [
        '<tool name="execute">ruby -e \'puts 42\'</tool>',
        "The answer is 42."
      ]
      allow(client).to receive(:complete).and_return(*responses)
      result = kernel.run([{ role: "user", content: "what is 42?" }])
      expect(result).to eq("The answer is 42.")
    end

    it "includes tool results in the follow-up prompt" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? '<tool name="memory_info"></tool>' : "done"
      end
      kernel.run([{ role: "user", content: "check memory" }])
      expect(prompts[1]).to include("Tool results")
    end

    it "returns an error message for unknown tools in the follow-up prompt" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? '<tool name="bogus">stuff</tool>' : "OK"
      end
      kernel.run([{ role: "user", content: "test" }])
      expect(prompts[1]).to include("unknown tool")
    end

    it "stops after max_iterations to prevent runaway loops" do
      call_count = 0
      allow(client).to receive(:complete) do
        call_count += 1
        '<tool name="memory_info"></tool>'
      end
      kernel.run([{ role: "user", content: "loop" }], max_iterations: 3)
      expect(call_count).to eq(3)
    end

    it "does not mutate the original messages array" do
      original = [{ role: "user", content: "hi" }]
      allow(client).to receive(:complete).and_return("hello")
      kernel.run(original)
      expect(original.length).to eq(1)
    end

    it "handles multiple tool calls in a single response" do
      responses = [
        '<tool name="memory_info"></tool><tool name="memory_info"></tool>',
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)
      result = kernel.run([{ role: "user", content: "twice" }])
      expect(result).to eq("done")
    end

    it "handles write tool calls with a path attribute" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        if prompts.length == 1
          '<tool name="write" path="/tmp/samagotchi_test_write.txt">hello</tool>'
        else
          "wrote it"
        end
      end
      result = kernel.run([{ role: "user", content: "write a file" }])
      expect(result).to eq("wrote it")
      expect(prompts[1]).to include("[write]")
    ensure
      FileUtils.rm_f("/tmp/samagotchi_test_write.txt")
    end
  end
end
