# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require "samagotchi/llm/openai_chat"
require_relative "../../script/llm_context_bench/cli"
require_relative "../support/fake_provider_server"
require_relative "bench_fixtures"

# --live end to end: the CLI's LivePick over chi's own chat client
# (LLM::OpenAIChat) against a fake OpenAI-compatible server, never a model.
RSpec.describe "llm_context_bench --live over HTTP" do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start }
  let(:dir) { Dir.mktmpdir("bench-live-http-") }
  let(:out_dir) { File.join(dir, "picks") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:path) { "/v1/chat/completions" }

  before do
    %w[aaaaaaaa bbbbbbbb].each do |prefix|
      BenchFixtures.write_session(dir, messages: BenchFixtures.chat_messages, id: "#{prefix}-0000-4000-8000-000000000000")
    end
  end

  after do
    server.stop
    FileUtils.rm_rf(dir)
  end

  def run(*argv)
    adapter = Samagotchi::LLM::OpenAIChat.new(base_url: server.base_url, host_name: "box", sleeper: ->(_s) {})
    LLMContextBench::CLI.new([dir, "--live", "box:acme/coder-1", "--out", out_dir, "--min-turn-tool", "0", *argv],
                             env: {}, out: out, err: err, chat_adapter: ->(_ref) { [adapter, "acme/coder-1"] }).run
  end

  def chunk(delta = {}, finish: nil) = "data: #{JSON.generate(choices: [{ index: 0, delta: delta, finish_reason: finish }])}\n\n"

  # A streamed answer: a forget call (or +text+ alone), its finish, then a
  # usage chunk with OpenRouter's cost when +cost+ is given.
  def answer(ids: nil, text: nil, finish: nil, cost: nil)
    chunks = []
    chunks << chunk({ content: text }) if text
    if ids
      call = { index: 0, id: "call_1", type: "function",
               function: { name: "forget_outputs", arguments: JSON.generate(ids: ids, note: "noted") } }
      chunks << chunk({ tool_calls: [call] })
    end
    chunks << chunk({}, finish: finish || (ids ? "tool_calls" : "stop"))
    usage = { prompt_tokens: 900, completion_tokens: 40 }
    usage[:cost] = cost if cost
    chunks << "data: #{JSON.generate(choices: [], usage: usage)}\n\n"
    chunks << "data: [DONE]\n\n"
  end

  def picks = Dir.glob(File.join(out_dir, "*.json")).map { |file| File.basename(file) }.sort

  describe "a payment error" do
    it "stops the run at a 402, saves nothing for that case, and exits 1" do
      server.enqueue(path, sse: answer(ids: ["t1"]))
      server.enqueue(path, status: 402, json: { error: { message: "Insufficient credits. Add more using https://openrouter.ai/credits" } })

      expect(run).to eq(1)
      expect(picks).to eq(%w[aaaaaaaa_t0.pick_forget_outputs_subtask_s1.json])
      expect(server.requests.size).to eq(2)
      expect(err.string).to include("stopped, a payment error: out of credits on host box",
                                    "1 picks written to #{out_dir} before it")
      expect(out.string).to be_empty
    end

    it "stops on an error that mentions the balance, whatever its status" do
      server.enqueue(path, status: 400, json: { error: { message: "Insufficient account balance" } })

      expect(run).to eq(1)
      expect(picks).to be_empty
      expect(server.requests.size).to eq(1)
    end
  end

  it "keeps any other error per case: an error record, then the next case" do
    server.enqueue(path, status: 400, json: { error: { message: "unknown parameter" } })
    server.enqueue(path, sse: answer(ids: ["t1"]))

    expect(run).to eq(0)
    expect(picks.size).to eq(2)
    record = JSON.parse(File.read(File.join(out_dir, "aaaaaaaa_t0.pick_forget_outputs_subtask_s1.json")))
    expect(record["unforced"]["error"]).to include("unknown parameter")
    expect(out.string).to start_with("2 picks written to #{out_dir} (0 forced, 0 of them after a reply cut at max_tokens; 1 errors)")
  end

  it "flags a forced retry after a reply cut off at max_tokens, and counts those in the last line" do
    server.enqueue(path, sse: answer(text: "Let me read the cart again and", finish: "length"))
    server.enqueue(path, sse: answer(ids: ["t1"]))
    server.enqueue(path, sse: answer(text: "Done."))
    server.enqueue(path, sse: answer(ids: ["t2"]))

    expect(run).to eq(0)
    cut, plain = %w[aaaaaaaa bbbbbbbb].map do |prefix|
      JSON.parse(File.read(File.join(out_dir, "#{prefix}_t0.pick_forget_outputs_subtask_s1.json")))
    end
    expect(cut).to include("forced_because" => "length")
    expect(cut["unforced"]["choices"][0]["finish_reason"]).to eq("length")
    expect(plain).to include("forced_because" => "no_call")
    expect(server.requests[1].json["tool_choice"]).to eq("type" => "function", "function" => { "name" => "forget_outputs" })
    expect(out.string).to include("2 picks written to #{out_dir} (2 forced, 1 of them after a reply cut at max_tokens; 0 errors)")
  end
end
