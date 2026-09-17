# frozen_string_literal: true

require "samagotchi/kernel_loop"
require "fileutils"
require "tmpdir"

RSpec.describe Samagotchi::KernelLoop do
  let(:client) { instance_double(Samagotchi::Client) }
  subject(:kernel) { described_class.new(client: client) }

  around do |example|
    original_env = {
      "SAMAGOTCHI_DEFAULT_MODEL" => ENV["SAMAGOTCHI_DEFAULT_MODEL"],
      "SAMAGOTCHI_CONTEXT_STATUS" => ENV["SAMAGOTCHI_CONTEXT_STATUS"],
      "SAMAGOTCHI_CONTEXT_WINDOW_TOKENS" => ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"],
      "SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN" => ENV["SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"],
      "SAMAGOTCHI_CONTEXT_STATUS_THRESHOLDS" => ENV["SAMAGOTCHI_CONTEXT_STATUS_THRESHOLDS"],
      "SAMAGOTCHI_CONTEXT_STATUS_CADENCE" => ENV["SAMAGOTCHI_CONTEXT_STATUS_CADENCE"],
      "SAMAGOTCHI_DEFAULT_N_PREDICT" => ENV["SAMAGOTCHI_DEFAULT_N_PREDICT"]
    }

    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV.delete("SAMAGOTCHI_DEFAULT_N_PREDICT")

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

    it "escapes literal control tokens in tool results before reinserting them into the next prompt" do
      prompts = []
      allow(client).to receive(:complete) do |prompt|
        prompts << prompt
        prompts.length == 1 ? %(<|tool_call>call:execute{command: "ruby -e 'puts %q(<end_of_turn>); puts %q(<|tool_response>)'"}<tool_call|>) : "done"
      end

      kernel.run([{ role: "user", content: "check" }])

      expect(prompts[1]).to include("[[SAMAGOTCHI_LITERAL_TURN_END]]")
      expect(prompts[1]).to include("[[SAMAGOTCHI_LITERAL_TOOL_RESPONSE_OPEN]]")
      expect(prompts[1]).not_to include("stdout:\n<end_of_turn>\n<|tool_response>")
    end

    it "emits a :context_status stream event when entering a tracked threshold bucket" do
      prompts = []
      events = []
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

      result = kernel.run([{ role: "user", content: "hello" }], on_stream_event: ->(e) { events << e })
      status_events = events.select { |e| e[:type] == :context_status }

      expect(status_events.size).to eq(1)
      expect(status_events.first[:status]).to include("CONTEXT_STATUS")
      expect(status_events.first[:status]).to include("bucket=20plus")
      expect(status_events.first[:bucket]).to eq("20plus")
      # The model no longer receives the telemetry in the prompt.
      expect(prompts.first).not_to include("CONTEXT_STATUS")
      expect(result.context_status).to include(est_pct: 35.2, bucket: "20plus")
    end

    it "emits :context_status only on threshold transitions" do
      prompts = []
      events = []
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

      kernel.run([{ role: "user", content: "check" }], on_stream_event: ->(e) { events << e })
      status_events = events.select { |e| e[:type] == :context_status }

      expect(status_events.size).to eq(1)
      expect(status_events.first[:status]).to include("CONTEXT_STATUS")
      expect(status_events.first[:status]).to include("bucket=40plus")
      expect(prompts[0]).not_to include("CONTEXT_STATUS")
      expect(prompts[1]).not_to include("CONTEXT_STATUS")
    end

    it "prefers real server usage over the synthetic estimate when available" do
      prompts = []
      events = []
      responses = [
        %(<|tool_call>call:execute{command: "echo hi"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete) do |prompt, **kwargs|
        prompts << prompt
        kwargs[:on_chunk]&.call(
          content: responses.first,
          payload: { "usage" => { "prompt_tokens" => 120_000, "completion_tokens" => 80 }, "n_ctx" => 256_000 }
        )
        responses.shift
      end

      kernel.run([{ role: "user", content: "check" }], on_stream_event: ->(e) { events << e })
      status_events = events.select { |e| e[:type] == :context_status }

      expect(status_events.size).to eq(1)
      expect(status_events.first[:status]).to include("CONTEXT_STATUS")
      expect(status_events.first[:status]).to include("src=server")
      expect(status_events.first[:status]).to include("est_used_tokens=120000")
      expect(status_events.first[:status]).to include("bucket=40plus")
      expect(prompts.first).not_to include("CONTEXT_STATUS")
    end

    it "still falls back to the synthetic estimate when the server reports no usage" do
      prompts = []
      events = []
      allow(client).to receive(:complete) do |prompt, **kwargs|
        prompts << prompt
        kwargs[:on_chunk]&.call(content: "ok", payload: {})
        "ok"
      end
      allow(kernel).to receive(:estimate_context_usage).and_return(
        window_tokens: 256_000,
        estimated_used_tokens: 90_000,
        estimated_remaining_tokens: 166_000,
        estimated_pct: 35.2,
        source: "estimate"
      )

      result = kernel.run([{ role: "user", content: "hello" }], on_stream_event: ->(e) { events << e })
      status_events = events.select { |e| e[:type] == :context_status }

      expect(status_events.size).to eq(1)
      expect(status_events.first[:status]).to include("CONTEXT_STATUS")
      expect(status_events.first[:status]).to include("src=estimate")
      expect(status_events.first[:status]).to include("bucket=20plus")
      expect(prompts.first).not_to include("CONTEXT_STATUS")
      expect(result.context_status).to include(est_pct: 35.2, bucket: "20plus")
    end

    it "emits bucket-aware actionable guidance" do
      expect(kernel.send(:context_status_guidance, "20plus")).to include("proceed normally")
      expect(kernel.send(:context_status_guidance, "40plus")).to include("prefer targeted")
      expect(kernel.send(:context_status_guidance, "60plus")).to include("concise")
      expect(kernel.send(:context_status_guidance, "80plus")).to include("summarize")
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

    it "dispatches a canonical read call with line-range params" do
      responses = [
        %(<|tool_call>call:read{path: "Gemfile", start_line: 1, end_line: 1}<tool_call|>),
        "ok"
      ]
      allow(client).to receive(:complete).and_return(*responses)

      result = kernel.run([{ role: "user", content: "read first line" }])
      event = result.tool_activity.find { |entry| entry[:tool] == "read" }

      expect(result).to eq("ok")
      expect(event[:params]).to include("lines=1-1")
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

    it "raises effective max_iterations to 1000 when no_interrupt is true" do
      no_interrupt_kernel = described_class.new(client: client, no_interrupt: true)
      # Verify the instance variable is set correctly
      expect(no_interrupt_kernel.instance_variable_get(:@no_interrupt)).to be true
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

    it "restores escaped literal control tokens in final user-visible output" do
      allow(client).to receive(:complete).and_return("literal [[SAMAGOTCHI_LITERAL_TURN_END]] token")

      expect(kernel.run([{ role: "user", content: "answer" }])).to eq("literal <end_of_turn> token")
    end

    it "restores escaped literal control tokens in tool call params before dispatch" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "literal_tokens.txt")
        responses = [
          %(<|tool_call>call:write{path: "#{path}", content: "before [[SAMAGOTCHI_LITERAL_TURN_END]] after"}<tool_call|>),
          "done"
        ]
        allow(client).to receive(:complete).and_return(*responses)

        result = kernel.run([{ role: "user", content: "write literal token" }])

        expect(result).to eq("done")
        expect(File.read(path)).to eq("before <end_of_turn> after")
      end
    end

    it "forwards generation stream events when a callback is provided" do
      events = []

      allow(client).to receive(:complete) do |_prompt, **kwargs|
        on_chunk = kwargs[:on_chunk]
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

    it "returns a canceled result when client generation is cancelled" do
      allow(client).to receive(:complete).and_raise(Samagotchi::Client::RequestCancelled.new(:manual))

      result = kernel.run([{ role: "user", content: "hi" }])

      expect(result).to be_canceled
      expect(result.cancellation_reason).to eq(:manual)
      expect(result.output).to eq("")
      expect(result.conversation).to eq([{ role: "user", content: "hi" }])
      expect(result).not_to be_resumable
    end

    it "emits generation_cancelled stream event on cancellation" do
      events = []
      allow(client).to receive(:complete).and_raise(Samagotchi::Client::RequestCancelled.new(:ctrl_c))

      kernel.run(
        [{ role: "user", content: "hi" }],
        on_stream_event: ->(event) { events << event }
      )

      expect(events.map { |event| event[:type] }).to include(:generation_started, :generation_cancelled)
      cancelled = events.find { |event| event[:type] == :generation_cancelled }
      expect(cancelled[:reason]).to eq(:ctrl_c)
    end

    it "emits generation_retrying stream events from client retry callbacks" do
      events = []
      retry_client = Class.new do
        def complete(_prompt, on_retry: nil, **_kwargs)
          on_retry&.call(
            attempt: 1,
            max_retries: 5,
            next_delay: 0.5,
            error_class: "Errno::ECONNREFUSED",
            error_message: "Connection refused"
          )
          "ok"
        end
      end.new
      retry_kernel = described_class.new(client: retry_client)

      retry_kernel.run(
        [{ role: "user", content: "hi" }],
        on_stream_event: ->(event) { events << event }
      )

      retrying = events.find { |event| event[:type] == :generation_retrying }
      expect(retrying).not_to be_nil
      expect(retrying[:attempt]).to eq(1)
      expect(retrying[:max_retries]).to eq(5)
      expect(retrying[:next_delay]).to eq(0.5)
      expect(retrying[:error_class]).to eq("Errno::ECONNREFUSED")
    end

    it "emits tool_call_started events with tool call details" do
      events = []
      responses = [
        %(<|tool_call>call:read{path: "memories/refactoring_backlog.md"}<tool_call|>),
        "done"
      ]

      allow(client).to receive(:complete).and_return(*responses)

      kernel.run(
        [{ role: "user", content: "read memory file" }],
        on_stream_event: ->(event) { events << event }
      )

      tool_event = events.find { |event| event[:type] == :tool_call_started }
      expect(tool_event).not_to be_nil
      expect(tool_event).to include(tool: "read", call_index: 1, call_count: 1)
      expect(tool_event[:call]).to include(name: "read", content: "memories/refactoring_backlog.md")
      expect(tool_event[:params]).to eq('path="memories/refactoring_backlog.md"')
    end

    it "emits tool_call_completed events with activity details" do
      events = []
      responses = [
        %(<|tool_call>call:read{path: "README.md"}<tool_call|>),
        "done"
      ]

      allow(client).to receive(:complete).and_return(*responses)

      kernel.run(
        [{ role: "user", content: "read readme" }],
        on_stream_event: ->(event) { events << event }
      )

      tool_event = events.find { |event| event[:type] == :tool_call_completed }
      expect(tool_event).not_to be_nil
      expect(tool_event).to include(tool: "read", call_index: 1, call_count: 1)
      # README.md exceeds the default 10000-char cap, so the emitted output is
      # capped and flagged as truncated; the activity summary is unaffected.
      expect(tool_event[:output]).to start_with("[read]\n")
      expect(tool_event[:output].length).to be <= Samagotchi::KernelLoop::DEFAULT_MAX_TOOL_OUTPUT_CHARS
      expect(tool_event[:output_truncated]).to be(true)
      expect(tool_event[:activity]).to include(
        action: "reading file",
        tool: "read",
        params: 'path="README.md"',
        status: "ok"
      )
    end

    describe ":tool_call_completed output and output_truncated" do
      it "includes the dispatched output and flags output_truncated: false when within cap" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "small.txt")
          File.write(path, "hello world")
          events = []
          allow(client).to receive(:complete).and_return(
            %(<|tool_call>call:read{path: "#{path}"}<tool_call|>),
            "done"
          )
          kernel.run(
            [{ role: "user", content: "read" }],
            on_stream_event: ->(event) { events << event }
          )

          completed = events.find { |event| event[:type] == :tool_call_completed }
          expect(completed[:output]).to eq("[read]\nhello world")
          expect(completed[:output_truncated]).to be(false)
        end
      end

      it "truncates output to the cap and flags output_truncated: true" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "big.txt")
          File.write(path, "x" * 5000)
          events = []
          allow(client).to receive(:complete).and_return(
            %(<|tool_call>call:read{path: "#{path}"}<tool_call|>),
            "done"
          )
          kernel.run(
            [{ role: "user", content: "read" }],
            max_tool_output_chars: 1000,
            on_stream_event: ->(event) { events << event }
          )

          completed = events.find { |event| event[:type] == :tool_call_completed }
          expect(completed[:output].length).to eq(1000)
          expect(completed[:output].to_s.start_with?("[read]\n")).to be(true)
          expect(completed[:output_truncated]).to be(true)
        end
      end

      it "honors SAMAGOTCHI_MAX_TOOL_OUTPUT_CHARS for the default cap" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "big.txt")
          File.write(path, "z" * 5000)
          original = ENV["SAMAGOTCHI_MAX_TOOL_OUTPUT_CHARS"]
          ENV["SAMAGOTCHI_MAX_TOOL_OUTPUT_CHARS"] = "42"
          events = []
          allow(client).to receive(:complete).and_return(
            %(<|tool_call>call:read{path: "#{path}"}<tool_call|>),
            "done"
          )
          kernel.run([{ role: "user", content: "read" }], on_stream_event: ->(event) { events << event })

          completed = events.find { |event| event[:type] == :tool_call_completed }
          expect(completed[:output].length).to eq(42)
          expect(completed[:output_truncated]).to be(true)
        ensure
          original.nil? ? ENV.delete("SAMAGOTCHI_MAX_TOOL_OUTPUT_CHARS") : ENV["SAMAGOTCHI_MAX_TOOL_OUTPUT_CHARS"] = original
        end
      end

      it "carries the unknown-tool error string and error status" do
        events = []
        allow(client).to receive(:complete).and_return(
          %(<|tool_call>call:frobnicate{bogus: 1}<tool_call|>),
          "done"
        )
        kernel.run([{ role: "user", content: "call a missing tool" }], on_stream_event: ->(event) { events << event })

        completed = events.find { |event| event[:type] == :tool_call_completed }
        expect(completed[:output].to_s).to start_with("Error: unknown tool 'frobnicate'")
        expect(completed[:activity][:status]).to eq("error")
      end

      it "carries the raised tool's error string and error status" do
        allow(Samagotchi::Tools::Read).to receive(:call).and_raise(RuntimeError.new("boom"))
        events = []
        allow(client).to receive(:complete).and_return(
          %(<|tool_call>call:read{path: "x"}<tool_call|>),
          "done"
        )
        kernel.run([{ role: "user", content: "read" }], on_stream_event: ->(event) { events << event })

        completed = events.find { |event| event[:type] == :tool_call_completed }
        expect(completed[:output].to_s).to eq("[read] Error: boom")
        expect(completed[:activity][:status]).to eq("error")
      end

      it "carries its own matching output per call across multiple calls in one iteration" do
        Dir.mktmpdir do |dir|
          a = File.join(dir, "a.txt"); File.write(a, "AAAA")
          b = File.join(dir, "b.txt"); File.write(b, "BBBB")
          events = []
          allow(client).to receive(:complete).and_return(
            %(<|tool_call>call:read{path: "#{a}"}<tool_call|>
<|tool_call>call:read{path: "#{b}"}<tool_call|>),
            "done"
          )
          kernel.run([{ role: "user", content: "read both" }], on_stream_event: ->(event) { events << event })

          completed = events.select { |event| event[:type] == :tool_call_completed }
          expect(completed.length).to eq(2)
          outputs = completed.map { |event| event[:output] }
          expect(outputs).to include("[read]\nAAAA")
          expect(outputs).to include("[read]\nBBBB")
          completed.each { |event| expect(event[:output_truncated]).to be(false) }
        end
      end

      it "caps only the event, not the conversation tool_response content" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "big.txt")
          long = "y" * 5000
          File.write(path, long)
          allow(client).to receive(:complete).and_return(
            %(<|tool_call>call:read{path: "#{path}"}<tool_call|>),
            "done"
          )
          result = kernel.run([{ role: "user", content: "read" }], max_tool_output_chars: 1000)

          expect(result.output).to eq("done")
          tool_response = result.conversation.find { |message| message[:role] == "tool_response" }
          expect(tool_response[:content]).to include(long)
        end
      end
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

    it "dispatches a canonical edit call with line-range params" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "range_edit.txt")
        File.write(path, "line 1\nline 2\nline 3\n")

        responses = [
          %(<|tool_call>call:edit{path: "#{path}", new_text: "line 2 updated\\n", start_line: 2, end_line: 2}<tool_call|>),
          "done"
        ]
        allow(client).to receive(:complete).and_return(*responses)

        result = kernel.run([{ role: "user", content: "range edit" }])
        event = result.tool_activity.find { |entry| entry[:tool] == "edit" }

        expect(result).to eq("done")
        expect(event[:params]).to include("lines=2-2")
        expect(File.read(path)).to eq("line 1\nline 2 updated\nline 3\n")
      end
    end

    it "dispatches a native task_create call and records task activity" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          responses = [
            %(<|tool_call>call:task_create{command: "ruby -e 'puts 12'"}<tool_call|>),
            "done"
          ]
          allow(client).to receive(:complete).and_return(*responses)

          result = kernel.run([{ role: "user", content: "run in background" }])
          event = result.tool_activity.find { |entry| entry[:tool] == "task_create" }

          expect(result).to eq("done")
          expect(event[:action]).to eq("starting background task")
          expect(event[:params]).to include("command=")
        end
      end
    end

    it "parses native task_wait options" do
      call = kernel.parser.send(
        :native_call,
        "task_wait",
        'task_id: "task-1", timeout: 90, tail_lines: 5, done_pattern: "Done!"'
      )

      expect(call).to include(
        content: "task-1",
        timeout: "90",
        tail_lines: "5",
        done_pattern: "Done!"
      )
    end

    it "resolves memory_write name only (the `path` alias no longer satisfies the name slot)" do
      name_call = kernel.parser.send(:native_call, "memory_write", 'name: "secret_plan", scope: "project"')
      expect(name_call[:path]).to eq("secret_plan")

      # A stray `path:` (the file-tool alias the model tends to emit) must NOT
      # satisfy the name slot; it resolves to "" so the guard can reject it.
      path_call = kernel.parser.send(:native_call, "memory_write", 'path: "secret_plan", scope: "project"')
      expect(path_call[:path]).to eq("")
    end
  end

  describe "pending input injection" do
    let(:queue) { Samagotchi::PendingInputQueue.new }

    it "injects a queued message as one merged user message before the next iteration" do
      responses = [
        %(<|tool_call>call:execute{command: "true"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete) do
        response = responses.shift
        # Simulate the user queueing a steering message while the model's
        # tool-call response is being dispatched, before the next iteration.
        queue.push("also check the specs") if responses.length == 1
        response
      end

      result = kernel.run(
        [{ role: "user", content: "run tests" }],
        pending_input: queue.method(:drain)
      )

      expect(result).to eq("done")
      injected = result.conversation.select { |m| m[:role] == "user" && m[:content].include?("also check the specs") }
      expect(injected.length).to eq(1)
    end

    it "merges multiple queued lines into a single user message" do
      queue.push("first note")
      queue.push("second note")
      allow(client).to receive(:complete).and_return("done")

      result = kernel.run(
        [{ role: "user", content: "hi" }],
        pending_input: queue.method(:drain)
      )

      merged = result.conversation.select { |m| m[:role] == "user" && m[:content].include?("first note") }
      expect(merged.length).to eq(1)
      expect(merged.first[:content]).to eq("first note\n\nsecond note")
      expect(queue).to be_empty
    end

    it "emits :pending_input_merged with iteration, count and content" do
      events = []
      allow(client).to receive(:complete).and_return("done")
      queue.push("steer me")

      kernel.run(
        [{ role: "user", content: "hi" }],
        pending_input: queue.method(:drain),
        on_stream_event: ->(event) { events << event }
      )

      merged = events.find { |event| event[:type] == :pending_input_merged }
      expect(merged).not_to be_nil
      expect(merged[:iteration]).to eq(1)
      expect(merged[:count]).to eq(1)
      expect(merged[:content]).to eq("steer me")
    end

    it "converts the no-tool-calls break into continue when input is queued" do
      # First generation returns plain text (would normally end the turn), but
      # a queued message must keep the turn alive for one more round.
      steering = Samagotchi::PendingInputQueue.new
      responses = ["first answer", "second answer"]
      allow(client).to receive(:complete) do
        response = responses.shift
        # Steering arrives after the first plain-text answer, before the
        # no-tool-calls break decision is made.
        steering.push("follow-up question") if responses.length == 1
        response
      end

      events = []
      result = kernel.run(
        [{ role: "user", content: "hi" }],
        pending_input: steering.method(:drain),
        on_stream_event: ->(event) { events << event }
      )

      expect(result).to eq("second answer")
      expect(events.count { |event| event[:type] == :generation_started }).to eq(2)
      conversation = result.conversation
      follow_up = conversation.find_index { |m| m[:role] == "user" && m[:content] == "follow-up question" }
      final_model = conversation.rindex { |m| m[:role] == "model" }
      expect(follow_up).not_to be_nil
      expect(final_model).to be > follow_up
    end

    it "survives a draining proc that raises" do
      allow(client).to receive(:complete).and_return("done")
      bad_drain = -> { raise "boom" }

      result = kernel.run(
        [{ role: "user", content: "hi" }],
        pending_input: bad_drain
      )
      expect(result).to eq("done")
    end

    it "orders injected input after tool_response and before the next model reply" do
      responses = [
        %(<|tool_call>call:execute{command: "true"}<tool_call|>),
        "done"
      ]
      allow(client).to receive(:complete) do
        response = responses.shift
        queue.push("steering") if responses.length == 1
        response
      end

      result = kernel.run(
        [{ role: "user", content: "hi" }],
        pending_input: queue.method(:drain)
      )

      roles = result.conversation.map { |m| m[:role] }
      tool_idx = roles.index("tool_response")
      user_idx = result.conversation.index { |m| m[:role] == "user" && m[:content] == "steering" }
      model_idx = roles.rindex("model")
      expect(tool_idx).not_to be_nil
      expect(user_idx).to eq(tool_idx + 1)
      expect(model_idx).to be > user_idx
    end
  end

  describe "cancel salvage" do
    it "appends the partial visible reply marked interrupted to the conversation" do
      allow(client).to receive(:complete) do |*_args, **kwargs|
        kwargs[:on_chunk]&.call(content: "Let me check the fi", payload: {})
        raise Samagotchi::Client::RequestCancelled.new(:ctrl_c)
      end

      result = kernel.run([{ role: "user", content: "hi" }])

      expect(result).to be_canceled
      salvaged = result.conversation.find { |m| m[:role] == "model" && m[:interrupted] }
      expect(salvaged).not_to be_nil
      expect(salvaged[:content]).to include("Let me check the fi")
      expect(salvaged[:content]).to include("[interrupted]")
    end

    it "drops an unterminated tool_call fragment from the salvaged partial" do
      allow(client).to receive(:complete) do |*_args, **kwargs|
        # Visible prose followed by an OPEN tool_call block that never closes:
        # the splitter must not route any of the fragment into the text lane.
        kwargs[:on_chunk]&.call(content: "checking now. <|tool_call>call:execute{command: \"rm", payload: {})
        raise Samagotchi::Client::RequestCancelled.new(:ctrl_c)
      end

      result = kernel.run([{ role: "user", content: "hi" }])

      salvaged = result.conversation.find { |m| m[:interrupted] }
      expect(salvaged[:content]).to include("checking now.")
      expect(salvaged[:content]).not_to include("tool_call")
      expect(salvaged[:content]).not_to include("rm")
    end

    it "keeps completed tool calls and responses in the salvaged conversation" do
      call_count = 0
      allow(client).to receive(:complete) do |*_args, **kwargs|
        call_count += 1
        if call_count == 1
          %(<|tool_call>call:execute{command: "true"}<tool_call|>)
        else
          kwargs[:on_chunk]&.call(content: "partial", payload: {})
          raise Samagotchi::Client::RequestCancelled.new(:ctrl_c)
        end
      end

      result = kernel.run([{ role: "user", content: "hi" }])

      roles = result.conversation.map { |m| m[:role] }
      expect(roles).to include("tool_response")
      expect(result.conversation.last[:interrupted]).to be(true)
    end

    it "returns an unsalvaged conversation when nothing visible streamed" do
      allow(client).to receive(:complete).and_raise(Samagotchi::Client::RequestCancelled.new(:manual))

      result = kernel.run([{ role: "user", content: "hi" }])

      expect(result.conversation).to eq([{ role: "user", content: "hi" }])
      expect(result.conversation.none? { |m| m[:interrupted] }).to be(true)
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

    it "tags the verbose output with the resolved model id" do
      model_kernel = described_class.new(client: client, verbose: true, model_name: "qwen36:latest")
      allow(client).to receive(:complete).and_return("Hello!")
      expect { model_kernel.run([{ role: "user", content: "hi" }])}
        .to output(/\[model: .+\].*LLM response/m).to_stderr
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

    it "tags each log line with the resolved model id" do
      dir = Dir.mktmpdir("samagotchi-debug-log")
      log_path = File.join(dir, "samagotchi.log")
      kernel_with_log = described_class.new(
        client: client, log_file: log_path, model_name: "gemma4:latest"
      )

      allow(client).to receive(:complete).and_return("Hello!")
      expect { kernel_with_log.run([{ role: "user", content: "hi" }]) }.not_to output.to_stderr

      content = File.read(log_path)
      expect(content).to include("[model: ")
      expect(content).to include("LLM response")
      # The logged id is the resolved model, not the alias we passed in.
      expect(content).not_to include("[model: gemma4:latest]")
    ensure
      FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    end
  end

  # ── Qwen 3.6 tool-call parsing ────────────────────────────────────────────

  describe "Qwen 3.6 profile" do
    let(:qwen_profile) { Samagotchi::ModelProfile.qwen36 }
    subject(:qwen_kernel) { described_class.new(client: client, profile: qwen_profile) }

    it "parses a canonical Qwen 3.6 execute tool call" do
      prompts = []
      allow(client).to receive(:complete) do |prompt, **_kwargs|
        prompts << prompt
        prompts.length == 1 ? "<tool_call><function=execute><parameter=command>echo hello</parameter></function></tool_call>" : "done"
      end
      result = qwen_kernel.run([{ role: "user", content: "run" }])
      expect(result).to eq("done")
      expect(prompts[1]).to include("stdout:")
      expect(prompts[1]).to include("hello")
    end

    it "parses a Qwen 3.6 read tool call" do
      prompts = []
      allow(client).to receive(:complete) do |prompt, **_kwargs|
        prompts << prompt
        prompts.length == 1 ? "<tool_call><function=read><parameter=path>Gemfile</parameter></function></tool_call>" : "ok"
      end
      result = qwen_kernel.run([{ role: "user", content: "read" }])
      expect(result).to eq("ok")
      expect(prompts[1]).to include("[read]")
    end

    it "parses a Qwen task_list call" do
      prompts = []
      allow(client).to receive(:complete) do |prompt, **_kwargs|
        prompts << prompt
        prompts.length == 1 ? "<tool_call><function=task_list></function></tool_call>" : "ok"
      end

      result = qwen_kernel.run([{ role: "user", content: "list tasks" }])

      expect(result).to eq("ok")
      expect(prompts[1]).to include("[task_list]")
    end

    it "parses Qwen task_wait options" do
      call = qwen_kernel.parser.send(
        :qwen_call_to_internal,
        "task_wait",
        "task_id" => "task-1", "timeout" => "90", "tail_lines" => "5", "done_pattern" => "Done!"
      )

      expect(call).to include(
        content: "task-1",
        timeout: "90",
        tail_lines: "5",
        done_pattern: "Done!"
      )
    end

    it "uses task defaults for omitted Qwen optional parameters" do
      wait_call = qwen_kernel.parser.send(:qwen_call_to_internal, "task_wait", "task_id" => "task-1")
      create_call = qwen_kernel.parser.send(:qwen_call_to_internal, "task_create", "command" => "echo hi")

      expect(wait_call).to include(timeout: "", tail_lines: "", done_pattern: "")
      expect(create_call).to include(env: "")
    end

    it "parses a Qwen 3.6 write tool call" do
      dir = Dir.mktmpdir("qwen-test")
      file_path = File.join(dir, "test.txt")
      prompts = []

      allow(client).to receive(:complete) do |prompt, **_kwargs|
        prompts << prompt
        prompts.length == 1 ? %(<tool_call><function=write><parameter=path>#{file_path}</parameter><parameter=content>hello world</parameter></function></tool_call>) : "ok"
      end

      result = qwen_kernel.run([{ role: "user", content: "write" }])
      expect(result).to eq("ok")
      expect(File.read(file_path)).to eq("hello world")
    ensure
      FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    end

    it "trims the templating newline around a Qwen parameter value" do
      dir = Dir.mktmpdir("qwen-newline-test")
      file_path = File.join(dir, "test.txt")
      prompts = []

      allow(client).to receive(:complete) do |prompt, **_kwargs|
        prompts << prompt
        prompts.length == 1 ? %(<tool_call><function=write><parameter=path>\n#{file_path}\n</parameter><parameter=content>\nabc\ndef\n</parameter></function></tool_call>) : "ok"
      end

      result = qwen_kernel.run([{ role: "user", content: "write" }])
      expect(result).to eq("ok")
      expect(File.read(file_path)).to eq("abc\ndef")
    ensure
      FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    end

    it "preserves an intentional blank line beyond the single trimmed templating newline" do
      dir = Dir.mktmpdir("qwen-blank-line-test")
      file_path = File.join(dir, "test.txt")

      allow(client).to receive(:complete).and_return(
        %(<tool_call><function=write><parameter=path>#{file_path}</parameter><parameter=content>\n\nabc\n\n</parameter></function></tool_call>),
        "ok"
      )

      result = qwen_kernel.run([{ role: "user", content: "write" }])
      expect(result).to eq("ok")
      expect(File.read(file_path)).to eq("\nabc\n")
    end

    it "matches exact-match edit text located at the very start of the file despite a templating newline" do
      dir = Dir.mktmpdir("qwen-edit-start-test")
      file_path = File.join(dir, "test.txt")
      File.write(file_path, "hello world\nsecond line\n")

      allow(client).to receive(:complete).and_return(
        %(<tool_call><function=edit><parameter=path>#{file_path}</parameter><parameter=old_text>\nhello world\n</parameter><parameter=new_text>\ngoodbye world\n</parameter></function></tool_call>),
        "ok"
      )

      result = qwen_kernel.run([{ role: "user", content: "edit" }])
      expect(result).to eq("ok")
      expect(File.read(file_path)).to eq("goodbye world\nsecond line\n")
    ensure
      FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    end

    it "parses a tool call when assistant prose appears before the XML block" do
      prompts = []
      allow(client).to receive(:complete) do |prompt, **_kwargs|
        prompts << prompt
        prompts.length == 1 ? "I'll run that now.\n<tool_call><function=execute><parameter=command>ruby -e 'puts 5'</parameter></function></tool_call>" : "done"
      end

      result = qwen_kernel.run([{ role: "user", content: "run" }])

      expect(result).to eq("done")
      expect(prompts[1]).to include("stdout:")
      expect(prompts[1]).to include("5")
    end

    it "parses a qwen edit tool call when the function tag is missing its closing bracket" do
      dir = Dir.mktmpdir("qwen-edit-test")
      file_path = File.join(dir, "test.txt")
      File.write(file_path, "line 1\nline 2\nline 3\n")

      allow(client).to receive(:complete).and_return(
        %(<tool_call><function=edit<parameter=path>#{file_path}</parameter><parameter=new_text>line 2 updated\n</parameter><parameter=start_line>2</parameter><parameter=end_line>2</parameter></function></tool_call>),
        "ok"
      )

      result = qwen_kernel.run([{ role: "user", content: "edit" }])

      expect(result).to eq("ok")
      expect(File.read(file_path)).to eq("line 1\nline 2 updated\nline 3\n")
    ensure
      FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    end

    it "parses logged qwen arg_key/arg_value pairs when the function tag is missing its closing bracket" do
      dir = Dir.mktmpdir("qwen-edit-arg-test")
      file_path = File.join(dir, "test.txt")
      File.write(file_path, "line 1\nline 2\nline 3\n")

      allow(client).to receive(:complete).and_return(
        %(<tool_call><function=edit<arg_key>path</arg_key><arg_value>#{file_path}</arg_value><arg_key>new_text</arg_key><arg_value>line 2 updated\n</arg_value><arg_key>start_line</arg_key><arg_value>2</arg_value><arg_key>end_line</arg_key><arg_value>2</arg_value></function></tool_call>),
        "ok"
      )

      result = qwen_kernel.run([{ role: "user", content: "edit" }])

      expect(result).to eq("ok")
      expect(File.read(file_path)).to eq("line 1\nline 2 updated\nline 3\n")
    ensure
      FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    end

    it "recovers from an incomplete qwen tool call across generations" do
      prompts = []
      responses = [
        "<tool_call><function=execute><parameter=command>ruby -e 'puts 4'",
        "</parameter></function></tool_call>",
        "done"
      ]

      allow(client).to receive(:complete) do |prompt, **_kwargs|
        prompts << prompt
        responses.shift
      end

      result = qwen_kernel.run([{ role: "user", content: "run" }], max_iterations: 5)

      expect(result).to eq("done")
      expect(prompts[1]).to include("Continue the previous assistant message by finishing the open <tool_call> XML block")
      expect(prompts[2]).to include("stdout:")
      expect(prompts[2]).to include("4")
    end

    it "stops recovery attempts after the bounded qwen incomplete-call limit" do
      prompts = []
      allow(client).to receive(:complete) do |prompt, **_kwargs|
        prompts << prompt
        "<tool_call><function=execute><parameter=command>ruby -e 'puts 9'"
      end

      result = qwen_kernel.run([{ role: "user", content: "run" }], max_iterations: 6)

      expect(result.output).to include("<tool_call><function=execute>")
      expect(result).not_to be_resumable
      expect(prompts.length).to eq(3)
    end

    it "parses qwen memory_write parameters with mixed casing and aliases" do
      dir = Dir.mktmpdir("qwen-memory-test")
      prompts = []

      allow(client).to receive(:complete) do |prompt, **_kwargs|
        prompts << prompt
        if prompts.length == 1
          "<tool_call><function=MEMORY_WRITE><parameter=Name>secret_plan</parameter><parameter=Value># The Secret Plan\nPhase 1: Evolution.</parameter><parameter=Scope>project</parameter></function></tool_call>"
        else
          "ok"
        end
      end

      stub_const("Samagotchi::Tools::PROJECT_MEMORIES_DIR", dir)

      result = qwen_kernel.run([{ role: "user", content: "save memory" }])

      expect(result).to eq("ok")
      expect(File.read(File.join(dir, "secret_plan.md"))).to eq("# The Secret Plan\nPhase 1: Evolution.")
    ensure
      FileUtils.remove_entry(dir) if dir && File.directory?(dir)
    end

    it "resolves memory_write name only (the `path` alias no longer satisfies the name slot)" do
      name_call = qwen_kernel.parser.send(:qwen_call_to_internal, "memory_write", "name" => "secret_plan")
      expect(name_call[:path]).to eq("secret_plan")

      # A stray `path:` (the file-tool alias the model tends to emit) must NOT
      # satisfy the name slot; it resolves to "" so the guard can reject it.
      path_call = qwen_kernel.parser.send(:qwen_call_to_internal, "memory_write", "path" => "secret_plan")
      expect(path_call[:path]).to eq("")
    end

    it "strips Qwen think blocks from the final output" do
      allow(client).to receive(:complete).and_return("<think>This is my reasoning</think>Here is the answer")
      result = qwen_kernel.run([{ role: "user", content: "hi" }])
      expect(result).to eq("Here is the answer")
    end

    it "strips multiple Qwen think blocks" do
      allow(client).to receive(:complete)
        .and_return("<think>Step 1</think>Thinking about it...<think>Step 2</think>Final answer")
      result = qwen_kernel.run([{ role: "user", content: "hi" }])
      expect(result).to eq("Thinking about it...Final answer")
    end

    it "formats prompts with Qwen role prefixes" do
      prompts = []
      allow(client).to receive(:complete) do |prompt, **_kwargs|
        prompts << prompt
        "done"
      end

      messages = [
        { role: "system", content: "You are an assistant" },
        { role: "user", content: "Hi there" }
      ]
      qwen_kernel.run(messages)

      prompt = prompts[0]
      expect(prompt).to include("<|im_start|>system")
      expect(prompt).to include("<|im_end|>")
      expect(prompt).to include("<|im_start|>user")
      expect(prompt).to include("<|im_start|>assistant")
    end

    it "returns nil when no default.n_predict is configured" do
      original_xdg = ENV["XDG_CONFIG_HOME"]
      Dir.mktmpdir("samagotchi-empty") do |dir|
        ENV["XDG_CONFIG_HOME"] = dir
        Samagotchi::Config.reload!(cli_overrides: {}) rescue nil
        captured_kwargs = nil
        allow(client).to receive(:complete) do |_prompt, **kwargs|
          captured_kwargs = kwargs
          "done"
        end

        qwen_kernel.run([{ role: "user", content: "hi" }])

        expect(captured_kwargs[:n_predict]).to be_nil
      ensure
        ENV["XDG_CONFIG_HOME"] = original_xdg
        Samagotchi::Config.reload!(cli_overrides: {}) rescue nil
      end
    end

    it "uses default.n_predict from config" do
      original_xdg = ENV["XDG_CONFIG_HOME"]
      Dir.mktmpdir("samagotchi-npredict") do |dir|
        ENV["XDG_CONFIG_HOME"] = dir
        config_path = File.join(dir, "samagotchi", "config.yml")
        FileUtils.mkdir_p(File.dirname(config_path))
        File.write(config_path, "default:\n  n_predict: 4096\n")

        captured_kwargs = nil
        allow(client).to receive(:complete) do |_prompt, **kwargs|
          captured_kwargs = kwargs
          "done"
        end

        qwen_kernel.run([{ role: "user", content: "hi" }])

        expect(captured_kwargs[:n_predict]).to eq(4096)
      ensure
        ENV["XDG_CONFIG_HOME"] = original_xdg
      end
    end

    it "respects SAMAGOTCHI_DEFAULT_N_PREDICT env var" do
      captured_kwargs = nil
      ENV["SAMAGOTCHI_DEFAULT_N_PREDICT"] = "2048"
      allow(client).to receive(:complete) do |_prompt, **kwargs|
        captured_kwargs = kwargs
        "done"
      end

      qwen_kernel.run([{ role: "user", content: "hi" }])

      expect(captured_kwargs[:n_predict]).to eq(2048)
    ensure
      ENV.delete("SAMAGOTCHI_DEFAULT_N_PREDICT")
    end

    it "passes model from environment when configured" do
      captured_kwargs = nil
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Qwen3-14B-Instruct"
      allow(client).to receive(:complete) do |_prompt, **kwargs|
        captured_kwargs = kwargs
        "done"
      end

      qwen_kernel.run([{ role: "user", content: "hi" }])

      expect(captured_kwargs[:model]).to eq("Qwen3-14B-Instruct")
    ensure
      ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
    end

    it "prefers explicit model_name run override over environment" do
      captured_kwargs = nil
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "env-model"
      allow(client).to receive(:complete) do |_prompt, **kwargs|
        captured_kwargs = kwargs
        "done"
      end

      qwen_kernel.run([{ role: "user", content: "hi" }], model_name: "runtime-model")

      expect(captured_kwargs[:model]).to eq("runtime-model")
    ensure
      ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
    end

    it "handles orphaned closing </think> tags" do
      # Model might output incomplete blocks - ensure stray closing tags are removed
      allow(client).to receive(:complete).and_return(
        "</think>\nHello! This is the actual response."
      )
      result = qwen_kernel.run([{ role: "user", content: "hi" }])
      expect(result.output).not_to include("</think>")
      expect(result.output).to start_with("Hello!")
    end

    it "handles incomplete opening <think> tags without closing" do
      # Model might output incomplete blocks
      allow(client).to receive(:complete).and_return(
        "<think>This is unfinished\nHello! Here's the actual response."
      )
      result = qwen_kernel.run([{ role: "user", content: "hi" }])
      expect(result).not_to include("<think>")
      expect(result).to include("Hello! Here's the actual response.")
    end

    it "removes multiple consecutive think blocks cleanly" do
      # Model outputs multiple thought blocks with actual content between
      allow(client).to receive(:complete).and_return(
        "<think>First thought</think>\nSome output\n<think>Second thought</think>\nMore output"
      )
      result = qwen_kernel.run([{ role: "user", content: "hi" }])
      expect(result).not_to include("<think>")
      expect(result).not_to include("</think>")
      expect(result).to include("Some output")
      expect(result).to include("More output")
    end
  end

  describe "profile inference from model" do
    around do |example|
      original = ENV.fetch("SAMAGOTCHI_DEFAULT_MODEL", nil)
      original_xdg = ENV["XDG_CONFIG_HOME"]
      Dir.mktmpdir("samagotchi-empty") do |dir|
        ENV["XDG_CONFIG_HOME"] = dir
        Samagotchi::Config.reload!(cli_overrides: {}) rescue nil
        example.run
      ensure
        if original.nil?
          ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
        else
          ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
        end
        ENV["XDG_CONFIG_HOME"] = original_xdg
        Samagotchi::Config.reload!(cli_overrides: {}) rescue nil
      end
    end

    it "raises when SAMAGOTCHI_DEFAULT_MODEL is unset" do
      ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
      expect { described_class.new(client: client) }
        .to raise_error(ArgumentError, /SAMAGOTCHI_DEFAULT_MODEL is required/)
    end

    it "infers qwen36 when SAMAGOTCHI_DEFAULT_MODEL contains qwen" do
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Qwen3-14B-Instruct"
      kernel = described_class.new(client: client)
      expect(kernel.instance_variable_get(:@profile).name).to eq("qwen36")
    end

    it "infers gemma4 for non-qwen model names" do
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
      kernel = described_class.new(client: client)
      expect(kernel.instance_variable_get(:@profile).name).to eq("gemma4")
    end

    it "respects explicit profile argument over env var" do
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
      kernel = described_class.new(client: client, profile: Samagotchi::ModelProfile.qwen36)
      expect(kernel.instance_variable_get(:@profile).name).to eq("qwen36")
    end
  end

  describe "model_key" do
    it "accepts model_key on initialization" do
      kernel = described_class.new(client: client, model_key: "gemma4o")
      expect(kernel.model_key).to eq("gemma4o")
    end

    it "defaults to nil" do
      kernel = described_class.new(client: client)
      expect(kernel.model_key).to be_nil
    end

    it "sync_model_key! updates the key" do
      kernel = described_class.new(client: client, model_key: "initial")
      kernel.sync_model_key!("updated")
      expect(kernel.model_key).to eq("updated")
    end
  end

  describe "#truthy?" do
    let(:kernel) { described_class.new(client: client) }

    it "coerces true" do
      expect(kernel.send(:truthy?, true)).to be true
    end

    it "coerces false" do
      expect(kernel.send(:truthy?, false)).to be false
    end

    it "coerces nil" do
      expect(kernel.send(:truthy?, nil)).to be false
    end

    it "coerces string 'true'" do
      expect(kernel.send(:truthy?, "true")).to be true
    end

    it "coerces string 'false'" do
      expect(kernel.send(:truthy?, "false")).to be false
    end

    it "coerces other strings" do
      expect(kernel.send(:truthy?, "1")).to be false
      expect(kernel.send(:truthy?, "yes")).to be false
    end
  end
end
