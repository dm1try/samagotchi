# frozen_string_literal: true

require "samagotchi/tool_runner"
require "samagotchi/tool_response"
require "samagotchi/message_parts"
require "samagotchi/hooks"
require "support/test_kernel"

# A long output's web preview on tool_call_completed (ToolRunner) is the text
# a reload's row has (MessageParts#tool_part) from the saved entry: through
# the joined content, its SEPARATOR split and the "[name]" lead, on the
# native batch and the chat single, for a read (its head) and an execute (its
# head and tail).
RSpec.describe "a long tool output's web preview, live and reloaded" do
  let(:hooks) { Samagotchi::Hooks::Registry.new }
  let(:outputs) do
    {
      "read" => (1..400).map { |n| "line #{n} of the file" }.join("\n"),
      "execute" => (1..400).map { |n| "step #{n} ok" }.join("\n") + "\nexit: 0"
    }
  end
  let(:kernel) do
    texts = outputs
    k = Struct.new(:hooks, :tools, :guardrail_gate) do
      define_method(:dispatch_tool_call) do |call, _context = nil|
        { output: "[#{call[:name]}]\n#{texts.fetch(call[:name])}", activity: { tool: call[:name], status: "ok" } }
      end
    end
    k.new(hooks)
  end
  let(:runner) { Samagotchi::ToolRunner.new(kernel) }
  let(:context) { run_context(tools: kernel.tools) }
  let(:events) { [] }
  let(:calls) { [{ name: "read", path: "big.txt" }, { name: "execute", content: "make" }] }

  def run_batch(ids)
    Samagotchi::ToolResponse.run_batch(runner, calls, context: context, iteration: 1, emit: ->(_e) {},
                                                      on_stream_event: ->(e) { events << e }, cap: nil, ids: ids)
  end

  def previews = events.select { |e| e[:type] == :tool_call_completed }.map { |e| e[:preview] }

  it "is past the cap only (a short output has none)" do
    outputs["read"] = "short"
    run_batch(%w[t1 t2])

    expect(previews.first).to be_nil
    expect(previews.last.length).to be <= Samagotchi::ToolOutputCut::WEB_PREVIEW_CHARS + 200
  end

  it "equals the reloaded part's output for a native batch of two" do
    runs = run_batch(%w[t1 t2])
    entry = Samagotchi::ToolResponse.joined(runs, ids: %w[t1 t2])
    message = { role: "model",
                content: %(<|tool_call>call:read{path: "big.txt"}<tool_call|><|tool_call>call:execute{command: "make"}<tool_call|>) }

    reloaded = Samagotchi::MessageParts.for_message(message, [entry])[:tools]

    expect(reloaded.map { |part| part[:output] }).to eq(previews)
    expect(previews.first).to eq("[read]\n#{outputs["read"]}"[0, Samagotchi::ToolOutputCut::WEB_PREVIEW_CHARS])
    expect(previews.last).to end_with("exit: 0")
  end

  it "equals the reloaded part's output for chat singles" do
    runs = run_batch(%w[t1 t2])
    responses = runs.each_with_index.map do |run, index|
      Samagotchi::ToolResponse.single(run, tool_call_id: "c#{index}", ids: ["t#{index + 1}"])
    end
    message = { role: "model", content: "",
                tool_calls: [{ id: "c0", name: "read", arguments: { "path" => "big.txt" } },
                             { id: "c1", name: "execute", arguments: { "command" => "make" } }] }

    reloaded = Samagotchi::MessageParts.for_message(message, responses)[:tools]

    expect(reloaded.map { |part| part[:output] }).to eq(previews)
    expect(previews).to all(be_a(String))
  end
end
