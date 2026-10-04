# frozen_string_literal: true

require "spec_helper"
require "samagotchi/client"
require "samagotchi/kernel_loop"
require "samagotchi/cancellation_controller"
require "samagotchi/llm/chat_loop"
require "samagotchi/llm/openai_chat"
require_relative "support/fake_provider_server"
require_relative "support/test_kernel"

# A generation a plugin cuts (CancellationController#cancel_generation!, what
# stop_generation calls) is an empty answer made early: both loops ask again
# with the cut nudge while retry.empty_answer lasts, else the turn ends as
# cancelled (hook). Over real HTTP: the cut closes the first stream's socket
# from inside the chunk callback, on the turn's thread.
RSpec.describe "A cut generation" do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start }
  let(:controller) { Samagotchi::CancellationController.new }
  let(:events) { [] }
  let(:cut) { { by: "loop-guard", reason: "its thinking kept repeating itself" } }
  let(:nudge) { Samagotchi::TurnNote.cut_retry("loop-guard", "its thinking kept repeating itself") }
  let(:loop_sentence) { "I should check the file again to be sure. " }
  # A steer's cut (Engine#cut_for_steer): no nudge, no attempt spent.
  let(:steer_cut) { { by: "steer", steer: true, source: "", reason: "a new message" } }

  after { server.stop }

  def with_limit(value)
    original = ENV.fetch("SAMAGOTCHI_RETRY_EMPTY_ANSWER", nil)
    ENV["SAMAGOTCHI_RETRY_EMPTY_ANSWER"] = value.to_s
    yield
  ensure
    original.nil? ? ENV.delete("SAMAGOTCHI_RETRY_EMPTY_ANSWER") : ENV["SAMAGOTCHI_RETRY_EMPTY_ANSWER"] = original
  end

  # Cuts the first generation after +after+ chunks, as a hook would, on the
  # same thread; then runs +also+ on each event.
  def sink(after: 3, iteration: 1, &also)
    chunks = 0
    lambda do |event|
      events << event
      if event[:type] == :generation_chunk && event[:iteration] == iteration
        chunks += 1
        controller.cancel_generation!(:hook, cut) if chunks == after
      end
      also&.call(event)
    end
  end

  def of_type(type) = events.select { |e| e[:type] == type }

  # The model requests (not the /props or /models probes).
  def completions = server.requests.select { |r| r.path.end_with?("completion", "completions") }

  # Queues +line+ (when given) and cuts, as a steer from the user does.
  def steer_sink(after: 3, queue: nil, line: nil)
    chunks = 0
    lambda do |event|
      events << event
      if event[:type] == :generation_chunk && event[:iteration] == 1
        chunks += 1
        if chunks == after
          queue << line if line
          controller.cancel_generation!(:steer, steer_cut)
        end
      end
      yield event if block_given?
    end
  end

  shared_examples "a steer cut" do
    it "sends the queued line next, with no nudge and no retry spent, and without the cut thinking" do
      stream_loop
      stream_answer("PONG")
      queue = []

      result = run_turn(steer_sink(queue: queue, line: "skip the tests"), pending_input: -> { queue.shift(queue.size) })

      expect(answer_of(result)).to eq("PONG")
      expect(completions.size).to eq(2)
      expect(completions[1].body).to include(Samagotchi::Steer::USER_HEADER, "skip the tests")
      expect(completions[1].body).not_to include("check the file again")
      expect(completions[1].body).not_to include(nudge[:content])
      expect(completions.map(&:json)).to all(satisfy { |json| !json.key?("temperature") })
      expect(of_type(:empty_answer_retry)).to be_empty
      expect(of_type(:generation_completed).first).to include(iteration: 1, stopped_by: "steer")
      expect(of_type(:pending_input_merged)).to contain_exactly(include(iteration: 1, count: 1))
      types = events.map { |e| e[:type] }
      expect(of_type(:steer_cut)).to eq([{ type: :steer_cut, iteration: 1, source: "" }])
      expect(types.index(:steer_cut)).to be < types.index(:pending_input_merged)
      expect(result.conversation.map { |m| m[:kind] }).to include("input")
      expect(controller).not_to be_cancelled
    end

    it "asks again as is when nothing is queued, with the budget left untouched" do
      stream_loop
      stream_answer("PONG")

      result = with_limit(0) { run_turn(steer_sink) }

      expect(answer_of(result)).to eq("PONG")
      expect(completions.size).to eq(2)
      expect(completions[1].body).not_to include("check the file again")
      expect(of_type(:empty_answer_retry)).to be_empty
      expect(result.conversation.map { |m| m[:role] }).to eq(%w[user model])
    end

    it "is a plain cancel when the user stops right after the steer's cut" do
      stream_loop
      stream_answer("PONG")
      queue = []
      stop = ->(event) { controller.cancel!(:user) if event[:stopped_by] && event[:type] == :generation_completed }

      result = run_turn(steer_sink(queue: queue, line: "skip the tests", &stop), pending_input: -> { queue.shift(queue.size) })

      expect(result).to be_canceled
      expect(result.cancellation_reason).to eq(:user)
      expect(completions.size).to eq(1)
      expect(queue).to eq(["skip the tests"])
    end
  end

  shared_examples "a cut generation" do
    it "asks again with the cut nudge last, at the retry temperature, and answers" do
      stream_loop
      stream_answer("PONG")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      result = run_turn(sink)

      expect(answer_of(result)).to eq("PONG")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
      expect(completions.size).to eq(2)
      expect(last_input(completions[1])).to eq(nudge[:content])
      expect(completions[1].body).not_to include("check the file again")
      expect(completions.first.json).not_to have_key("temperature")
      expect(completions.last.json["temperature"]).to eq(0.6)
      expect(result.conversation.first(2)).to eq([{ role: "user", content: "hi" }, nudge])
      expect(result.conversation.map { |m| m[:role] }).to eq(%w[user system model])
      expect(result.conversation.last[:content]).to end_with("PONG")
      expect(of_type(:generation_completed).first).to include(iteration: 1, finish_reason: "stopped",
                                                              stopped_by: "loop-guard", content_length: 0)
      expect(of_type(:generation_completed).first[:thinking_chars]).to be_positive
      expect(of_type(:empty_answer_retry)).to contain_exactly(include(iteration: 1, attempt: 1, of: 1, stopped_by: "loop-guard"))
      expect(of_type(:generation_cancelled)).to be_empty
      expect(controller).not_to be_cancelled
    end

    it "ends cancelled (hook) with nothing salvaged when no retry is left" do
      stream_loop(text: "Partial visible answer ")

      result = with_limit(0) { run_turn(sink(after: 6)) }

      expect(result).to be_canceled
      expect(result.cancellation_reason).to eq(:hook)
      expect(result.conversation).to eq([{ role: "user", content: "hi" }])
      expect(completions.size).to eq(1)
      expect(controller.reason).to eq(:hook)
      expect(controller.detail).to include(by: "loop-guard")
    end

    it "drops the spent nudge when a second cut finds the retry used up" do
      stream_loop
      stream_loop

      result = run_turn(sink_both)

      expect(result).to be_canceled
      expect(result.cancellation_reason).to eq(:hook)
      expect(result.conversation).to eq([{ role: "user", content: "hi" }])
      expect(completions.size).to eq(2)
    end

    it "is a plain cancel when the user stops right after the cut" do
      stream_loop
      stream_answer("PONG")

      result = run_turn(sink { |event| controller.cancel!(:user) if event[:stopped_by] && event[:type] == :generation_completed })

      expect(result).to be_canceled
      expect(result.cancellation_reason).to eq(:user)
      expect(completions.size).to eq(1)
      expect(of_type(:empty_answer_retry)).to be_empty
    end

    it "still cancels on the user's Stop during the retry" do
      stream_loop
      stream_loop

      result = run_turn(sink { |event| controller.cancel!(:user) if event[:type] == :generation_chunk && event[:iteration] == 2 })

      expect(result).to be_canceled
      expect(result.cancellation_reason).to eq(:user)
      expect(completions.size).to eq(2)
    end

    it "drops visible text the cut generation had streamed" do
      stream_loop(text: "Half an answer that ")
      stream_answer("PONG")

      result = run_turn(sink(after: 6))

      expect(answer_of(result)).to eq("PONG")
      expect(result.conversation.map { |m| m[:content].to_s }.join).not_to include("Half an answer")
    end
  end

  # A cut on each generation of the turn.
  def sink_both
    chunks = Hash.new(0)
    lambda do |event|
      events << event
      next unless event[:type] == :generation_chunk

      chunks[event[:iteration]] += 1
      controller.cancel_generation!(:hook, cut) if chunks[event[:iteration]] == 3
    end
  end

  describe "on the native path (/completion)" do
    let(:client) { Samagotchi::Client.new(host: "127.0.0.1", port: server.port, transport: :llama_cpp, sleeper: ->(_s) {}) }
    let(:kernel) { Samagotchi::KernelLoop.new(client: client, profile: Samagotchi::ModelProfile.qwen36) }

    def event(content) = "data: #{JSON.generate(content: content)}\n\n"

    # Thinking that never ends (held open), then visible +text+ if given.
    def stream_loop(text: nil)
      chunks = [event("<think>")] + Array.new(4) { event(loop_sentence) }
      chunks += [event("</think>"), *text.to_s.scan(/\S+ ?/).map { |word| event(word) }] if text
      server.enqueue("/completion", sse: chunks, delay: 0.01, hold: true)
    end

    def stream_answer(text, thinking: "short")
      server.enqueue("/completion", sse: [event("<think>"), event(thinking), event("</think>"), event(text),
                                          "data: #{JSON.generate(content: "", stop: true)}\n\n"])
    end

    def run_turn(on_event, pending_input: nil)
      kernel.run([{ role: "user", content: "hi" }], on_stream_event: on_event, cancel_controller: controller,
                                                    pending_input: pending_input)
    end

    def answer_of(result) = result.output

    def last_input(request)
      request.json["prompt"].to_s[/<\|im_start\|>system\n(.*?)<\|im_end\|>\n<\|im_start\|>assistant\n\z/m, 1]
    end

    it_behaves_like "a cut generation"
    it_behaves_like "a steer cut"

    it "splits the retry's thinking with a fresh splitter after a cut mid-block" do
      stream_loop
      stream_answer("PONG", thinking: "short")

      run_turn(sink)

      retry_chunks = of_type(:generation_chunk).select { |e| e[:iteration] == 2 }
      expect(retry_chunks.map { |e| e[:thinking] }.join).to eq("short")
    end

    it "leaves no tool-call recovery state after a cut mid-<tool_call>" do
      server.enqueue("/completion", sse: [event("<tool_call>\n"), event("<function=read>\n"),
                                          *Array.new(4) { event("<parameter=path>\na</parameter>\n") }],
                                    delay: 0.01, hold: true)
      stream_answer("PONG")

      result = run_turn(sink)

      expect(result.output).to eq("PONG")
      expect(completions.size).to eq(2)
      expect(completions[1].json["prompt"]).not_to include("<tool_call>")
    end
  end

  describe "on the chat path (api: openai)" do
    let(:adapter) { Samagotchi::LLM::OpenAIChat.new(base_url: server.base_url, host_name: "box", sleeper: ->(_s) {}) }
    let(:kernel) do
      test_kernel.tap do |kernel|
        allow(kernel).to receive(:strip_model_thought) { |text| text.to_s.strip }
      end
    end
    let(:backend) { Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter) }

    def delta(fields = {}, finish: nil, **more)
      "data: #{JSON.generate(choices: [{ index: 0, delta: fields.merge(more), finish_reason: finish }])}\n\n"
    end

    def stream_loop(text: nil)
      chunks = Array.new(5) { delta(reasoning_content: loop_sentence) }
      chunks += text.to_s.scan(/\S+ ?/).map { |word| delta(content: word) } if text
      server.enqueue("/v1/chat/completions", sse: chunks, delay: 0.01, hold: true)
    end

    def stream_answer(text)
      server.enqueue("/v1/chat/completions", sse: [delta(reasoning_content: "short"), delta(content: text),
                                                   delta({}, finish: "stop"), "data: [DONE]\n\n"])
    end

    def run_turn(on_event, pending_input: nil)
      backend.complete(messages: [{ role: "user", content: "hi" }], model_name: "m", on_stream_event: on_event,
                       cancel_controller: controller, pending_input: pending_input)
    end

    def answer_of(result) = result.text

    def last_input(request) = request.json["messages"].last["content"]

    it_behaves_like "a cut generation"
    it_behaves_like "a steer cut"

    it "keeps the retry mark through the saved conversation" do
      stream_loop
      stream_answer("PONG")

      result = run_turn(sink)

      expect(result.conversation[1]).to include(retry_nudge: true, kind: "turn_note")
      expect(completions[1].json["messages"].last.keys).to contain_exactly("role", "content")
    end
  end
end
