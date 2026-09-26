# frozen_string_literal: true

require "spec_helper"
require "samagotchi/web/message_parts"

RSpec.describe Samagotchi::Web::MessageParts do
  def qwen_call(name, params)
    body = params.map { |k, v| "<parameter=#{k}>\n#{v}\n</parameter>\n" }.join
    "<tool_call>\n<function=#{name}>\n#{body}</function>\n</tool_call>"
  end

  describe ".for_message on the native loop's markup (a profile, llama.cpp)" do
    it "reads the thinking, each call's params and its piece of the joined output" do
      content = "<think>\nLook first.\n</think>\n\nLet me check.\n#{qwen_call('execute', command: 'ls -la')}\n" \
                "#{qwen_call('read', path: 'README.md', start_line: 1, end_line: 3)}"
      response = { role: "tool_response", content: "[execute]\na\nb\n\n---\n\n[read]\n1: # Title" }

      expect(described_class.for_message({ role: "model", content: content }, [response])).to eq(
        thinking: "Look first.",
        tools: [
          { tool: "execute", params: 'command="ls -la"', output: "[execute]\na\nb" },
          { tool: "read", params: 'path="README.md" lines=1-3', output: "[read]\n1: # Title" }
        ]
      )
    end

    it "keeps an output that holds the joiner itself whole (the split is at the next [tool] tag)" do
      content = "#{qwen_call('read', path: 'a.md')}#{qwen_call('execute', command: 'true')}"
      response = { content: "[read]\nabove\n\n---\n\nbelow\n\n---\n\n[execute]\n" }

      tools = described_class.for_message({ content: content }, [response])[:tools]
      expect(tools.map { |t| t[:output] }).to eq(["[read]\nabove\n\n---\n\nbelow", "[execute]\n"])
    end

    it "takes thinking the chat template opened (no <think> in the saved text)" do
      expect(described_class.for_message({ content: "planning\n</think>\n\nThe answer." }, [])).to eq(thinking: "planning")
    end

    it "reads Gemma's thought channel and tool-call markup" do
      content = '<|channel>thought pondering<channel|>Sure.<|tool_call>call:execute{command:<|"|>pwd<|"|>}<tool_call|>'
      parts = described_class.for_message({ "role" => "model", "content" => content }, [{ "content" => "[execute]\n/tmp" }])

      expect(parts).to eq(thinking: "pondering", tools: [{ tool: "execute", params: 'command="pwd"', output: "[execute]\n/tmp" }])
    end

    it "gives no parts for a plain answer" do
      expect(described_class.for_message({ content: "Just text." }, [])).to be_nil
    end

    it "caps a long output" do
      part = described_class.for_message({ content: qwen_call("read", path: "big") }, [{ content: "x" * 5000 }])[:tools].first

      expect(part[:output].length).to eq(described_class::OUTPUT_MAX)
      expect(part[:output_truncated]).to be(true)
    end

    it "leaves the output out when there is no tool_response (a canceled turn)" do
      expect(described_class.for_message({ content: qwen_call("execute", command: "sleep 9") }, [])).to eq(
        tools: [{ tool: "execute", params: 'command="sleep 9"' }]
      )
    end
  end

  describe ".for_message on the chat loop's tool_calls (api: openai)" do
    it "pairs each call with its tool_response by id (symbol keys from disk)" do
      message = { role: "model", content: "Checking.",
                  tool_calls: [{ id: "c1", name: "execute", arguments: { "command" => "true" } },
                               { id: "c2", name: "read", arguments: { "path" => "README.md" } }] }
      responses = [{ role: "tool_response", content: "[read]\nhello", tool_call_id: "c2" },
                   { role: "tool_response", content: "[execute]\n", tool_call_id: "c1" }]

      expect(described_class.for_message(message, responses)).to eq(
        tools: [{ tool: "execute", params: 'command="true"', output: "[execute]\n" },
                { tool: "read", params: 'path="README.md"', output: "[read]\nhello" }]
      )
    end

    it "reads a Bridge snapshot's string keys" do
      message = { "role" => "model", "content" => "",
                  "tool_calls" => [{ "id" => "c1", "name" => "execute", "arguments" => { "command" => "echo hi" } }] }

      expect(described_class.for_message(message, [{ "content" => "[execute]\nhi", "tool_call_id" => "c1" }])).to eq(
        tools: [{ tool: "execute", params: 'command="echo hi"', output: "[execute]\nhi" }]
      )
    end

    it "reads the reasoning the chat loop saved as thinking (trimmed), next to the calls" do
      message = { role: "model", content: "", thinking: "\nrun it first\n",
                  tool_calls: [{ id: "c1", name: "execute", arguments: { "command" => "true" } }] }

      expect(described_class.for_message(message, [{ content: "[execute]\n", tool_call_id: "c1" }])).to eq(
        thinking: "run it first", tools: [{ tool: "execute", params: 'command="true"', output: "[execute]\n" }]
      )
    end

    it "gives an answer's saved thinking as its only part (string keys too)" do
      expect(described_class.for_message({ "role" => "model", "content" => "Done.", "thinking" => "it passed" }, [])).to eq(
        thinking: "it passed"
      )
    end

    it "gives nothing for an older message without the key, or a blank one" do
      expect(described_class.for_message({ role: "model", content: "Done." }, [])).to be_nil
      expect(described_class.for_message({ role: "model", content: "Done.", thinking: " \n" }, [])).to be_nil
    end
  end

  describe "a plugin tool" do
    let(:qwen) { qwen_call("echo_args", text: "BANANA42", times: 3) }
    let(:output) { [{ content: "[echo_args]\necho: text=BANANA42 times=3 (Integer)" }] }

    it "shows its arguments as key=\"value\" without a registry that knows it (the web's reload)" do
      gemma = '<|tool_call>call:echo_args{text:<|"|>BANANA42<|"|>,times:3}<tool_call|>'
      chat = { content: "", tool_calls: [{ id: "c1", name: "echo_args", arguments: { "text" => "BANANA42", "times" => 3 } }] }
      [described_class.for_message({ content: qwen }, output), described_class.for_message({ content: gemma }, output),
       described_class.for_message(chat, [{ content: "x", tool_call_id: "c1" }])].each do |parts|
        expect(parts[:tools].first).to include(tool: "echo_args", params: 'text="BANANA42" times="3"')
      end
    end

    it "shows its preview from a registry that has it" do
      registry = Samagotchi::Tools::Builtins.registry
      registry.register("echo_args", schema: { parameters: { properties: { times: { type: "integer" } } } },
                                     handler: ->(*) { "" }, source: "sample-plugin",
                                     preview: ->(call) { "#{call[:args]["text"]} ×#{call[:args]["times"]}" })
      expect(described_class.for_message({ content: qwen }, output, registry: registry)[:tools].first[:params]).to eq("BANANA42 ×3")
    end

    it "prefers the params line saved with the result (tool_params) over the registry" do
      saved = [{ content: output.first[:content], tool_params: ["BANANA42 ×3"] }]
      expect(described_class.for_message({ content: qwen }, saved)[:tools].first[:params]).to eq("BANANA42 ×3")
      chat = { content: "", tool_calls: [{ id: "c1", name: "echo_args", arguments: { "text" => "BANANA42" } }] }
      expect(described_class.for_message(chat, [{ "content" => "x", "tool_call_id" => "c1", "tool_params" => "saved" }])[:tools].first[:params])
        .to eq("saved")
    end

    it "keeps a built-in's own params next to a saved plugin line (nil in the list)" do
      content = qwen_call("execute", command: "ls") + qwen
      saved = [{ content: "[execute]\nok\n\n---\n\n#{output.first[:content]}", tool_params: [nil, "BANANA42 ×3"] }]
      expect(described_class.for_message({ content: content }, saved)[:tools].map { |t| t[:params] })
        .to eq(['command="ls"', "BANANA42 ×3"])
    end

    it "gives the part the label saved with the result (tool_labels), none for a built-in" do
      content = qwen_call("execute", command: "ls") + qwen
      saved = [{ content: "[execute]\nok\n\n---\n\n#{output.first[:content]}", tool_labels: [nil, "echo: args"] }]
      tools = described_class.for_message({ content: content }, saved)[:tools]
      expect(tools.map { |t| t[:label] }).to eq([nil, "echo: args"])
      expect(tools.first).not_to have_key(:label)
      chat = { content: "", tool_calls: [{ id: "c1", name: "echo_args", arguments: {} }] }
      expect(described_class.for_message(chat, [{ "content" => "x", "tool_call_id" => "c1", "tool_labels" => "echo: args" }])[:tools].first)
        .to include(tool: "echo_args", label: "echo: args")
    end

    it "ignores a saved list whose length doesn't match the calls" do
      saved = [{ content: output.first[:content], tool_params: %w[a b] }]
      expect(described_class.for_message({ content: qwen }, saved)[:tools].first[:params]).to eq('text="BANANA42" times="3"')
    end
  end

  describe "a message it can't read" do
    it "gives no tools for an unclosed call block" do
      expect(described_class.for_message({ content: "<tool_call>\n<function=execute>\n<parameter=command>\nls" }, [])).to be_nil
    end

    it "gives nil, not an error, when parsing raises" do
      allow_any_instance_of(Samagotchi::ToolCallParser::Qwen).to receive(:parse).and_raise(ArgumentError, "boom")

      expect(described_class.for_message({ content: qwen_call("execute", command: "ls") }, [])).to be_nil
    end
  end

  describe "a call's images (the tool row's thumbs after a reload)" do
    let(:shot) { { "file" => "images/aaaaaaaaaaaaaaaa.png", "name" => "shot.png", "width" => 3, "height" => 2, "mime" => "image/png", "bytes" => 9, "source" => "tool" } }
    let(:gif) { shot.merge("file" => "images/bbbbbbbbbbbbbbbb.gif", "name" => "a.gif") }
    let(:shown) { { file: "images/aaaaaaaaaaaaaaaa.png", name: "shot.png", width: 3, height: 2 } }

    it "native: splits the joined list by image_counts, each call its own" do
      content = "#{qwen_call('read', path: 'a.png')}#{qwen_call('execute', command: 'true')}#{qwen_call('shots', {})}"
      response = { "content" => "[read]\nImage\n\n---\n\n[execute]\n\n\n---\n\n[shots]\ntwo",
                   "images" => [shot, gif, shot], "image_counts" => [1, 0, 2] }

      tools = described_class.for_message({ content: content }, [response])[:tools]
      expect(tools.map { |t| t[:images]&.map { |i| i[:name] } }).to eq([["shot.png"], nil, ["a.gif", "shot.png"]])
      expect(tools.first[:images]).to eq([shown])
    end

    it "native, an older session without image_counts: a lone call gets them, several get none" do
      one = described_class.for_message({ content: qwen_call("read", path: "a.png") }, [{ content: "[read]\nx", images: [shot] }])
      expect(one[:tools].first[:images]).to eq([shown])
      two = described_class.for_message({ content: "#{qwen_call('read', path: 'a')}#{qwen_call('read', path: 'b')}" },
                                        [{ content: "[read]\nx\n\n---\n\n[read]\ny", images: [shot] }])
      expect(two[:tools].map { |t| t[:images] }).to eq([nil, nil])
    end

    it "chat: each call's images from its own tool_response" do
      message = { role: "model", content: "", tool_calls: [{ id: "c1", name: "execute", arguments: {} },
                                                           { id: "c2", name: "shots", arguments: {} }] }
      responses = [{ content: "[execute]\n", tool_call_id: "c1" }, { content: "[shots]\ntwo", tool_call_id: "c2", images: [shot] }]
      tools = described_class.for_message(message, responses)[:tools]
      expect(tools.map { |t| t[:images] }).to eq([nil, [shown]])
    end
  end
end
