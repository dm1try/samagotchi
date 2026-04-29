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
        prompts.length == 1 ? '<tool name="execute">echo hi</tool>' : "done"
      end
      kernel.run([{ role: "user", content: "check" }])
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
        '<tool name="execute">echo loop</tool>'
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
        '<tool name="execute">echo one</tool><tool name="execute">echo two</tool>',
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

    # ── Native Gemma 4 format ──────────────────────────────────────────────────

    it "dispatches a native execute call and continues the loop" do
      responses = [
        %(<|tool_call>call:execute{command: "ruby -e 'puts 7'"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)
      result = kernel.run([{ role: "user", content: "run ruby" }])
      expect(result).to eq("done")
    end

    it "includes native tool results in the follow-up prompt" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? %(<|tool_call>call:execute{command: "echo hi"}<tool_call|>) : "done"
      end
      kernel.run([{ role: "user", content: "run?" }])
      expect(prompts[1]).to include("Tool results")
      expect(prompts[1]).to include("[execute]")
    end

    it "dispatches a native read call with the correct path" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? %(<|tool_call>call:read{path: "Gemfile"}<tool_call|>) : "ok"
      end
      kernel.run([{ role: "user", content: "read gemfile" }])
      expect(prompts[1]).to include("[read]")
    end

    it "dispatches a native write call with path and content params" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        if prompts.length == 1
          %(<|tool_call>call:write{path: "/tmp/native_write_test.txt", content: "hello native"}<tool_call|>)
        else
          "written"
        end
      end
      result = kernel.run([{ role: "user", content: "write" }])
      expect(result).to eq("written")
      expect(prompts[1]).to include("[write]")
    ensure
      FileUtils.rm_f("/tmp/native_write_test.txt")
    end

    it "handles the exact model output format from the reported issue" do
      # This is the exact string the model emitted that caused the loop to exit
      model_output = %(<|channel>thought\n<channel|><|tool_call>call:execute{command: "ls -R"}<tool_call|>)
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? model_output : "finished"
      end
      result = kernel.run([{ role: "user", content: "list files" }])
      expect(result).to eq("finished")
      expect(prompts[1]).to include("[execute]")
    end

    it "stops after max_iterations with native tool calls" do
      call_count = 0
      allow(client).to receive(:complete) do
        call_count += 1
        %(<|tool_call>call:execute{command: "echo loop"}<tool_call|>)
      end
      kernel.run([{ role: "user", content: "loop" }], max_iterations: 3)
      expect(call_count).to eq(3)
    end

    it "returns an error message for unknown native tools" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? "<|tool_call>call:unknown_tool{command: \"hi\"}<tool_call|>" : "OK"
      end
      kernel.run([{ role: "user", content: "test" }])
      expect(prompts[1]).to include("unknown tool")
    end
  end

  describe "verbose mode" do
    subject(:verbose_kernel) { described_class.new(client: client, verbose: true) }

    it "prints the raw LLM response to stderr when verbose" do
      allow(client).to receive(:complete).and_return("Hello!")
      expect { verbose_kernel.run([{ role: "user", content: "hi" }]) }
        .to output(/LLM response.*Hello!/m).to_stderr
    end

    it "prints tool call details to stderr when verbose" do
      responses = ['<tool name="execute">echo hi</tool>', "done"]
      allow(client).to receive(:complete).and_return(*responses)
      expect { verbose_kernel.run([{ role: "user", content: "go" }]) }
        .to output(/tool call: execute.*echo hi/m).to_stderr
    end

    it "prints tool result to stderr when verbose" do
      responses = ['<tool name="execute">echo hi</tool>', "done"]
      allow(client).to receive(:complete).and_return(*responses)
      expect { verbose_kernel.run([{ role: "user", content: "go" }]) }
        .to output(/tool result: execute/m).to_stderr
    end

    it "prints tool error to stderr when verbose" do
      responses = ['<tool name="execute">ruby -e "raise \'boom\'"</tool>', "done"]
      allow(client).to receive(:complete).and_return(*responses)
      expect { verbose_kernel.run([{ role: "user", content: "go" }]) }
        .to output(/tool (result|error): execute/m).to_stderr
    end

    it "does not print to stderr when verbose is false (default)" do
      allow(client).to receive(:complete).and_return("Hello!")
      expect { kernel.run([{ role: "user", content: "hi" }]) }
        .not_to output.to_stderr
    end
  end
end
