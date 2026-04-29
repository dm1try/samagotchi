# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "fileutils"

RSpec.describe Samagotchi::KernelLoop do
  # Minimal stand-in for Samagotchi::Client
  let(:client) { instance_double(Samagotchi::Client) }
  subject(:kernel) { described_class.new(client: client) }

  describe "#run" do
    it "returns empty string when response is only an unclosed legacy thought block" do
      allow(client).to receive(:complete).and_return("<|channel>thought")
      result = kernel.run([{ role: "user", content: "hi" }])
      expect(result).to eq("")
    end

    it "strips legacy thought blocks from the final response" do
      allow(client).to receive(:complete)
        .and_return("<|channel>thought\nsome internal reasoning\n<channel|>Hello!")
      result = kernel.run([{ role: "user", content: "hi" }])
      expect(result).to eq("Hello!")
    end

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

    # ── Native Gemma 4 canonical format ───────────────────────────────────────

    it "dispatches a native execute call and continues the loop" do
      responses = [
        %(<|tool>declaration:execute{command: "ruby -e 'puts 7'"}),
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
        prompts.length == 1 ? %(<|tool>declaration:execute{command: "echo hi"}) : "done"
      end
      kernel.run([{ role: "user", content: "run?" }])
      expect(prompts[1]).to include("Tool results")
      expect(prompts[1]).to include("[execute]")
    end

    it "dispatches a native read call with the correct path" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? %(<|tool>declaration:read{path: "Gemfile"}) : "ok"
      end
      kernel.run([{ role: "user", content: "read gemfile" }])
      expect(prompts[1]).to include("[read]")
    end

    it "dispatches a native write call with path and content params" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        if prompts.length == 1
          %(<|tool>declaration:write{path: "/tmp/native_write_test.txt", content: "hello native"})
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

    it "handles the exact model output format from the reported issue (legacy fallback)" do
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

    it "handles the canonical equivalent: thought block immediately followed by a tool call" do
      model_output = %(<|think|>\n<|tool>declaration:execute{command: "ls -R"})
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? model_output : "finished"
      end
      result = kernel.run([{ role: "user", content: "list files" }])
      expect(result).to eq("finished")
      expect(prompts[1]).to include("[execute]")
    end

    it "does not execute tool calls embedded inside thought blocks" do
      # The model mentions a tool call with extra/wrong params inside its thought,
      # then emits the real call outside. Only the real call should be dispatched.
      model_output = <<~OUT
        <|think|>
        I could run: <tool name="execute">echo wrong --extra-param</tool>
        But the correct command is simpler.
        <|tool>declaration:execute{command: "echo correct"}
      OUT
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? model_output : "done"
      end
      kernel.run([{ role: "user", content: "run something" }])
      # Only one execute result in the tool-results block; the thought-block command was not run
      expect(prompts[1]).not_to include("stdout:\nwrong")
      expect(prompts[1]).to include("stdout:\ncorrect")
    end

    it "does not execute native tool calls embedded inside thought blocks" do
      model_output = <<~OUT
        <|think|>
        I might use XML: <tool name="execute">echo inside-thought</tool>
        Actually use the proper command.
        <|tool>declaration:execute{command: "echo outside-thought"}
      OUT
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? model_output : "done"
      end
      kernel.run([{ role: "user", content: "run" }])
      expect(prompts[1]).not_to include("stdout:\ninside-thought")
      expect(prompts[1]).to include("stdout:\noutside-thought")
    end

    it "does not execute legacy native tool calls embedded inside legacy thought blocks" do
      model_output = <<~OUT
        <|channel>thought
        I might call: <|tool_call>call:execute{command: "echo inside-thought"}<tool_call|>
        Actually use the proper command.
        <channel|>
        <|tool_call>call:execute{command: "echo outside-thought"}<tool_call|>
      OUT
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? model_output : "done"
      end
      kernel.run([{ role: "user", content: "run" }])
      expect(prompts[1]).not_to include("stdout:\ninside-thought")
      expect(prompts[1]).to include("stdout:\noutside-thought")
    end

    it "stops after max_iterations with native tool calls" do
      call_count = 0
      allow(client).to receive(:complete) do
        call_count += 1
        %(<|tool>declaration:execute{command: "echo loop"})
      end
      kernel.run([{ role: "user", content: "loop" }], max_iterations: 3)
      expect(call_count).to eq(3)
    end

    it "returns an error message for unknown native tools" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? %(<|tool>declaration:unknown_tool{command: "hi"}) : "OK"
      end
      kernel.run([{ role: "user", content: "test" }])
      expect(prompts[1]).to include("unknown tool")
    end

    # ── Legacy native format (backward compatibility) ─────────────────────────

    it "dispatches a legacy native execute call and continues the loop" do
      responses = [
        %(<|tool_call>call:execute{command: "ruby -e 'puts 7'"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)
      result = kernel.run([{ role: "user", content: "run ruby" }])
      expect(result).to eq("done")
    end

    it "returns an error message for unknown legacy native tools" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? "<|tool_call>call:unknown_tool{command: \"hi\"}<tool_call|>" : "OK"
      end
      kernel.run([{ role: "user", content: "test" }])
      expect(prompts[1]).to include("unknown tool")
    end

    # ── Unquoted / no-space param values ─────────────────────────────────────
    # The model sometimes emits {command:ruby -e '...'} without quotes or a
    # space after the colon.  The harness must strip the "command:" prefix and
    # execute the real command, not the raw fragment.

    it "strips the 'command:' prefix when the value is unquoted (legacy format)" do
      # Exact pattern from the reported failure:
      # call:execute{command:ruby -e 'puts rand(100).to_s'}
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        if prompts.length == 1
          "<|tool_call>call:execute{command:echo hello}<tool_call|>"
        else
          "done"
        end
      end
      kernel.run([{ role: "user", content: "run" }])
      expect(prompts[1]).to include("stdout:\nhello")
    end

    it "strips the 'command:' prefix when the value is unquoted (canonical format)" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? "<|tool>declaration:execute{command:echo hello}" : "done"
      end
      kernel.run([{ role: "user", content: "run" }])
      expect(prompts[1]).to include("stdout:\nhello")
    end

    it "strips the 'path:' prefix when the value is unquoted (read, legacy format)" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? "<|tool_call>call:read{path:Gemfile}<tool_call|>" : "ok"
      end
      kernel.run([{ role: "user", content: "read gemfile" }])
      expect(prompts[1]).to include("[read]")
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
