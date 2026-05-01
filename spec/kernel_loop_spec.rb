# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "fileutils"
require "tmpdir"

RSpec.describe Samagotchi::KernelLoop do
  let(:client) { instance_double(Samagotchi::Client) }
  subject(:kernel) { described_class.new(client: client) }

  around do |example|
    original_env = {
      "SAMAGOTCHI_CONTEXT_STATUS" => ENV["SAMAGOTCHI_CONTEXT_STATUS"],
      "SAMAGOTCHI_CONTEXT_WINDOW_TOKENS" => ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"],
      "SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN" => ENV["SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"],
      "SAMAGOTCHI_CONTEXT_STATUS_THRESHOLDS" => ENV["SAMAGOTCHI_CONTEXT_STATUS_THRESHOLDS"],
      "SAMAGOTCHI_CONTEXT_STATUS_CADENCE" => ENV["SAMAGOTCHI_CONTEXT_STATUS_CADENCE"]
    }

    example.run
  ensure
    original_env.each { |key, value| ENV[key] = value }
  end

  describe "#run" do
    it "returns the model response when no tool calls are present" do
      allow(client).to receive(:complete).and_return("Hello!")
      expect(kernel.run([{ role: "user", content: "hi" }])).to eq("Hello!")
    end

    it "supports String-style include? checks on the returned result" do
      allow(client).to receive(:complete).and_return("Hello world")
      expect(kernel.run([{ role: "user", content: "hi" }])).to include("world")
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
      expect(result.tool_activity).to include(
        action: "running command",
        tool: "execute",
        params: "command=\"ruby -e 'puts 7'\"",
        status: "ok"
      )
    end

    it "captures concise tool activity with error status when a tool returns an error" do
      responses = [
        %(<|tool_call>call:read{path: "/definitely/missing/file.txt"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)
      result = kernel.run([{ role: "user", content: "read missing" }])

      expect(result).to eq("done")
      expect(result.tool_activity).to include(hash_including(action: "reading file", tool: "read", status: "error"))
    end

    it "truncates long command previews in tool activity" do
      long_command = "echo #{'x' * 120}"
      responses = [
        %(<|tool_call>call:execute{command: "#{long_command}"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete).and_return(*responses)

      result = kernel.run([{ role: "user", content: "run long command" }])
      params = result.tool_activity.find { |event| event[:tool] == "execute" }[:params]

      expect(params).to start_with("command=\"")
      expect(params).to end_with("…\"")
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

    it "emits a CONTEXT_STATUS system message when entering a tracked threshold bucket" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        "ok"
      end
      allow(kernel).to receive(:estimate_context_usage).and_return(
        window_tokens: 256_000,
        estimated_used_tokens: 90_000,
        estimated_remaining_tokens: 166_000,
        estimated_pct: 35.2
      )

      kernel.run([{ role: "user", content: "hello" }])

      expect(prompts.first).to include("CONTEXT_STATUS")
      expect(prompts.first).to include("bucket=20plus")
    end

    it "emits CONTEXT_STATUS only on threshold transitions" do
      prompts = []
      responses = [
        %(<|tool_call>call:execute{command: "echo hi"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        responses.shift
      end
      allow(kernel).to receive(:estimate_context_usage).and_return(
        {
          window_tokens: 256_000,
          estimated_used_tokens: 30_000,
          estimated_remaining_tokens: 226_000,
          estimated_pct: 11.7
        },
        {
          window_tokens: 256_000,
          estimated_used_tokens: 140_000,
          estimated_remaining_tokens: 116_000,
          estimated_pct: 54.6
        }
      )

      kernel.run([{ role: "user", content: "check" }])

      expect(prompts[0]).not_to include("CONTEXT_STATUS")
      expect(prompts[1]).to include("CONTEXT_STATUS")
      expect(prompts[1]).to include("bucket=40plus")
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

    it "strips emitted thought-channel output from the final response" do
      model_output = %(<|channel>thought
The user said "hello". I should respond briefly.
<channel|>Hello!)
      allow(client).to receive(:complete).and_return(model_output)
      expect(kernel.run([{ role: "user", content: "hello" }])).to eq("Hello!")
    end

    it "preserves tool dispatch when a thought-channel block precedes a tool call" do
      model_output = %(<|channel>thought
Need to inspect the filesystem first.
<channel|><|tool_call>call:execute{command: "echo after-channel"}<tool_call|>)
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? model_output : "finished"
      end
      result = kernel.run([{ role: "user", content: "run" }])
      expect(result).to eq("finished")
      expect(prompts[1]).to include("stdout:\nafter-channel")
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

    it "strips previous thought-channel output from history before the next standard turn" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        "ok"
      end

      history = [
        { role: "user", content: "first" },
        { role: "model", content: %(<|channel>thought\nprivate reasoning\n<channel|>Answer) },
        { role: "user", content: "second" }
      ]
      kernel.run(history)
      expect(prompts.first).not_to include("private reasoning")
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

    it "returns a resumable result when max_iterations is reached with tool calls pending" do
      allow(client).to receive(:complete)
        .and_return(%(<|tool_call>call:execute{command: "echo loop"}<tool_call|>))

      result = kernel.run([{ role: "user", content: "loop" }], max_iterations: 1)

      expect(result).to be_exhausted
      expect(result).to have_attributes(pending_tool_calls?: true, resumable?: true)
      expect(result.conversation.last[:role]).to eq("tool_response")
      expect(result.conversation.last[:content]).to include("[execute]")
    end

    it "can resume from a previous exhausted result" do
      prompts = []
      responses = [
        %(<|tool_call>call:execute{command: "echo resumed"}<tool_call|>),
        "finished"
      ]

      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        responses.shift
      end

      partial = kernel.run([{ role: "user", content: "resume" }], max_iterations: 1)
      result = kernel.run(partial, max_iterations: 2)

      expect(partial).to be_resumable
      expect(result.output).to eq("finished")
      expect(result).not_to be_resumable
      expect(prompts[1]).to include("[execute]")
      expect(prompts[1]).to include("stdout:\nresumed")
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

    it "forwards generation stream events when a callback is provided" do
      events = []

      allow(client).to receive(:complete) do |_prompt, on_chunk: nil|
        on_chunk&.call(content: "Hel", payload: { "content" => "Hel" })
        on_chunk&.call(content: "lo", payload: { "content" => "lo" })
        "Hello"
      end

      result = kernel.run(
        [{ role: "user", content: "hi" }],
        on_stream_event: ->(event) { events << event }
      )

      expect(result).to eq("Hello")
      expect(events.map { |event| event[:type] }).to include(:generation_started, :generation_chunk, :generation_completed)
      expect(events.count { |event| event[:type] == :generation_chunk }).to eq(2)
      expect(events.select { |event| event[:type] == :generation_chunk }.map { |event| event[:content] }).to eq(["Hel", "lo"])
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

  describe "debug log file" do
    it "writes verbose-equivalent events to a file when verbose is false" do
      dir = Dir.mktmpdir("samagotchi-debug-log")
      log_path = File.join(dir, "samagotchi.log")
      kernel_with_log = described_class.new(client: client, log_file: log_path)

      allow(client).to receive(:complete).and_return("Hello!")
      expect { kernel_with_log.run([{ role: "user", content: "hi" }]) }
        .not_to output.to_stderr

      content = File.read(log_path)
      expect(content).to include("LLM response")
      expect(content).to include("Hello!")
    ensure
      FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    end

    it "writes to both stderr and file when verbose is true" do
      dir = Dir.mktmpdir("samagotchi-debug-log")
      log_path = File.join(dir, "samagotchi.log")
      kernel_with_log = described_class.new(client: client, verbose: true, log_file: log_path)

      allow(client).to receive(:complete).and_return("Hello!")
      expect { kernel_with_log.run([{ role: "user", content: "hi" }]) }
        .to output(/LLM response.*Hello!/m).to_stderr

      content = File.read(log_path)
      expect(content).to include("LLM response")
      expect(content).to include("Hello!")
    ensure
      FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    end

    it "does not fail the run when log path is not writable" do
      dir = Dir.mktmpdir("samagotchi-debug-log")
      kernel_with_bad_log = described_class.new(client: client, log_file: dir)

      allow(client).to receive(:complete).and_return("Hello!")
      expect(kernel_with_bad_log.run([{ role: "user", content: "hi" }]).to_s).to eq("Hello!")
    ensure
      FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    end
  end
end
