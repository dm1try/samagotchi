# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "fileutils"

RSpec.describe Samagotchi::KernelLoop do
  let(:client) { instance_double(Samagotchi::Client) }
  subject(:kernel) { described_class.new(client: client) }

  describe "#run" do
    it "returns the model response when no tool calls are present" do
      allow(client).to receive(:complete).and_return("Hello!")
      expect(kernel.run([{ role: "user", content: "hi" }])).to eq("Hello!")
    end

    it "does not mutate the original messages array" do
      original = [{ role: "user", content: "hi" }]
      allow(client).to receive(:complete).and_return("hello")
      kernel.run(original)
      expect(original.length).to eq(1)
    end

    it "dispatches a canonical execute call and continues the loop" do
      responses = [
        %(<|tool_call>call:execute{command: "ruby -e 'puts 7'"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)
      result = kernel.run([{ role: "user", content: "run ruby" }])
      expect(result).to eq("done")
    end

    it "injects tool results as a <|tool_response> block in the follow-up prompt" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? %(<|tool_call>call:execute{command: "echo hi"}<tool_call|>) : "done"
      end
      kernel.run([{ role: "user", content: "check" }])
      expect(prompts[1]).to include("<|tool_response>")
      expect(prompts[1]).to include("[execute]")
    end

    it "dispatches a canonical read call with the correct path" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? %(<|tool_call>call:read{path: "Gemfile"}<tool_call|>) : "ok"
      end
      kernel.run([{ role: "user", content: "read gemfile" }])
      expect(prompts[1]).to include("[read]")
    end

    it "dispatches a canonical write call with path and content params" do
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

    it "preserves raw thoughts between same-turn tool calls" do
      model_output = %(<|think|>plan first\n<|tool_call>call:execute{command: "echo one"}<tool_call|>)
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? model_output : "finished"
      end
      result = kernel.run([{ role: "user", content: "list files" }])
      expect(result).to eq("finished")
      expect(prompts[1]).to include("<|think|>plan first")
    end

    it "returns empty text when the final response is only a thought block" do
      model_output = %(<|think|>internal reasoning\nstill thought)
      allow(client).to receive(:complete).and_return(model_output)
      expect(kernel.run([{ role: "user", content: "answer" }])).to eq("")
    end

    it "strips previous model thoughts from history before the next standard turn" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        "ok"
      end

      history = [
        { role: "user", content: "first" },
        { role: "model", content: "Answer<|think|>private chain of thought" },
        { role: "user", content: "second" }
      ]
      kernel.run(history)
      expect(prompts.first).not_to include("private chain of thought")
      expect(prompts.first).to include("Answer")
    end

    it "stops after max_iterations to prevent runaway loops" do
      call_count = 0
      allow(client).to receive(:complete) do
        call_count += 1
        %(<|tool_call>call:execute{command: "echo loop"}<tool_call|>)
      end
      kernel.run([{ role: "user", content: "loop" }], max_iterations: 3)
      expect(call_count).to eq(3)
    end

    it "returns an error message for unknown canonical tools" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? %(<|tool_call>call:unknown_tool{command: "hi"}<tool_call|>) : "OK"
      end
      kernel.run([{ role: "user", content: "test" }])
      expect(prompts[1]).to include("unknown tool")
    end

    it "strips the 'command:' prefix when the value is unquoted" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? "<|tool_call>call:execute{command:echo hello}<tool_call|>" : "done"
      end
      kernel.run([{ role: "user", content: "run" }])
      expect(prompts[1]).to include("stdout:\nhello")
    end

    it "strips the 'path:' prefix when the value is unquoted (read)" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? "<|tool_call>call:read{path:Gemfile}<tool_call|>" : "ok"
      end
      kernel.run([{ role: "user", content: "read gemfile" }])
      expect(prompts[1]).to include("[read]")
    end

    # ── Gemma 4 <|"|> string delimiter ────────────────────────────────────────
    # Gemma 4 uses <|"|> as a delimiter for string values.  The harness must
    # not treat the <| part as a control-token boundary and must strip the
    # delimiter tokens so clean values reach the tools.

    it "parses a canonical execute call with Gemma string delimiters around the value" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? %(<|tool_call>call:execute{command:<|"|>echo hello<|"|>}<tool_call|>) : "done"
      end
      kernel.run([{ role: "user", content: "run" }])
      expect(prompts[1]).to include("stdout:\nhello")
    end

    it "parses a canonical read call with Gemma string delimiters" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? %(<|tool_call>call:read{path:<|"|>Gemfile<|"|>}<tool_call|>) : "ok"
      end
      kernel.run([{ role: "user", content: "read gemfile" }])
      expect(prompts[1]).to include("[read]")
    end

    it "does not cut canonical tool call body at the <| inside a Gemma string delimiter" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? %(<|tool_call>call:execute{command:<|"|>echo boundary<|"|>}<tool_call|>) : "done"
      end
      kernel.run([{ role: "user", content: "run" }])
      expect(prompts[1]).to include("stdout:\nboundary")
    end

    it "does not cut canonical thought block at a <| inside a Gemma string delimiter" do
      model_output = %(<|think|>use <|"|>value<|"|> form\n<|tool_call>call:execute{command: "echo after-thought"}<tool_call|>)
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? model_output : "done"
      end
      kernel.run([{ role: "user", content: "run" }])
      expect(prompts[1]).to include("stdout:\nafter-thought")
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
      responses = ['<|tool_call>call:execute{command: "echo hi"}<tool_call|>', "done"]
      allow(client).to receive(:complete).and_return(*responses)
      expect { verbose_kernel.run([{ role: "user", content: "go" }]) }
        .to output(/tool call: execute.*echo hi/m).to_stderr
    end

    it "prints tool result to stderr when verbose" do
      responses = ['<|tool_call>call:execute{command: "echo hi"}<tool_call|>', "done"]
      allow(client).to receive(:complete).and_return(*responses)
      expect { verbose_kernel.run([{ role: "user", content: "go" }]) }
        .to output(/tool result: execute/m).to_stderr
    end

    it "prints tool error to stderr when verbose" do
      responses = ['<|tool_call>call:execute{command: "ruby -e \"raise \'boom\'\""}<tool_call|>', "done"]
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
