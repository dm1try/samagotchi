# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require_relative "support/fake_chat_adapter"
require "support/test_kernel"

# A step-limit Continue (run_turn resume_from:) keeps the reasoning of the
# run it resumes on the chat loop under reasoning_history: turn, so its
# first request matches the last one before the limit; a reminder's or a
# wake's continue turn (no resume_from) starts a run of its own.
RSpec.describe Samagotchi::Engine, "a step-limit Continue's reasoning" do
  around do |example|
    with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it", "SAMAGOTCHI_REASONING_HISTORY" => "turn") { example.run }
  end

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:adapter) do
    FakeChatAdapter.new(call("c1", "plan"), call("c2", "more"), call("c3", "next"), FakeChatAdapter.text("done"))
  end

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(Samagotchi::Tools::Read).to receive(:call).and_return("x")
  end

  def use_chat_loop
    backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter)
    allow(engine).to receive(:backend_for).and_return(backend)
  end

  def call(id, reasoning)
    FakeChatAdapter.tools([id, "read", { "path" => "#{id}.rb" }]).with(reasoning: reasoning)
  end

  def reasoning_sent(request) = request[:messages].filter_map { |m| m[:reasoning_content] }

  # The turn that runs out of steps (2), and the request its Continue sends first.
  def continue_after_limit(**continue_args)
    use_chat_loop
    first = engine.run_turn(session, "go", max_iterations: 2)
    expect(first).to be_resumable
    before = adapter.requests.length
    engine.run_turn(session, nil, continue: true, max_iterations: 2, **continue_args.transform_values { |v| v.call(first) })
    adapter.requests[before]
  end

  it "sends the resumed run's reasoning: the request after the Continue goes on from the one before it" do
    request = continue_after_limit(resume_from: ->(first) { first.run_start })

    expect(reasoning_sent(request)).to eq(%w[plan more])
    expect(adapter.requests[1][:messages]).to eq(request[:messages].first(adapter.requests[1][:messages].length))
  end

  it "sends none of it on a continue without resume_from (a reminder's, a wake's)" do
    expect(reasoning_sent(continue_after_limit)).to eq([])
  end

  it "ignores (and logs) a resume_from past the conversation's end: only the reasoning goes" do
    allow(Samagotchi::Log).to receive(:warn).and_call_original

    request = continue_after_limit(resume_from: ->(_) { 99 })

    expect(reasoning_sent(request)).to eq([])
    expect(Samagotchi::Log).to have_received(:warn).with(:turn, "resume_start_invalid", resume_from: 99, length: anything)
  end

  # The native loop: the saved run (its model messages raw, thought and
  # all) goes back into the Continue's prompt with its thoughts.
  describe "on the native loop" do
    let(:raw) { %(<|channel>thought\nplan the listing\n<channel|><|tool_call>call:read{path: "a.rb"}<tool_call|>) }

    def prompts_after_limit(**continue_args)
      prompts = []
      allow(client).to receive(:complete) do |prompt, **|
        prompts << prompt
        prompts.length == 1 ? raw : "done"
      end
      first = engine.run_turn(session, "go", max_iterations: 1)
      expect(first).to be_resumable
      engine.run_turn(session, nil, continue: true, **continue_args.transform_values { |v| v.call(first) })
      prompts
    end

    it "keeps the resumed run's thought in the Continue's prompt" do
      prompts = prompts_after_limit(resume_from: ->(first) { first.run_start })

      expect(prompts.last).to include("plan the listing")
    end

    # Inside one native run nothing re-sanitizes: a steer merged mid-run
    # leaves the earlier thoughts in the prompt, so the Continue keeps them
    # too, or its prompt stops matching the one before the limit.
    it "keeps the thoughts before a steer the resumed run merged: the prompt before the limit is a prefix of the next" do
      prompts = []
      allow(client).to receive(:complete) do |prompt, **|
        prompts << prompt
        n = prompts.length
        n > 3 ? "done" : %(<|channel>thought\nthink #{n}\n<channel|><|tool_call>call:read{path: "#{n}.rb"}<tool_call|>)
      end
      queue = [[], ["also this"], []]
      first = engine.run_turn(session, "go", max_iterations: 3, pending_input: -> { queue.shift || [] })
      expect(first).to be_resumable
      engine.run_turn(session, nil, continue: true, resume_from: first.run_start)

      expect(prompts[2]).to include("also this", "think 1")
      expect(prompts[3]).to start_with(prompts[2].delete_suffix("<|turn>model\n"))
      expect(prompts[3]).to include("think 1", "think 2", "think 3")
    end

    it "strips it on a continue without resume_from" do
      expect(prompts_after_limit.last).not_to include("plan the listing")
    end
  end
end
