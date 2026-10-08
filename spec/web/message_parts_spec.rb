# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "samagotchi/web/message_parts"

RSpec.describe Samagotchi::Web::MessageParts do
  def qwen_call(name, params)
    body = params.map { |k, v| "<parameter=#{k}>\n#{v}\n</parameter>\n" }.join
    "<tool_call>\n<function=#{name}>\n#{body}</function>\n</tool_call>"
  end

  describe ".for_message on the native loop's markup (a profile, llama.cpp)" do
    it "reads the thinking, each call's params and its piece of the joined output" do
      content = "<think>\nLook first.\n</think>\n\nLet me check.\n#{qwen_call("execute", command: "ls -la")}\n" \
                "#{qwen_call("read", path: "README.md", start_line: 1, end_line: 3)}"
      response = { role: "tool_response", content: "[execute]\na\nb\n\n---\n\n[read]\n1: # Title" }

      expect(described_class.for_message({ role: "model", content: content }, [response])).to eq(
        thinking: "Look first.",
        tools: [
          { tool: "execute", params: 'command="ls -la"', title: "ls -la", view: { command: "ls -la", steps: [{ text: "ls -la" }] }, output: "[execute]\na\nb" },
          { tool: "read", params: 'path="README.md" lines=1-3', title: "README.md", output: "[read]\n1: # Title" }
        ]
      )
    end

    it "keeps an output that holds the joiner itself whole (the split is at the next [tool] tag)" do
      content = "#{qwen_call("read", path: "a.md")}#{qwen_call("execute", command: "true")}"
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

      expect(parts).to eq(thinking: "pondering", tools: [{ tool: "execute", params: 'command="pwd"', title: "pwd", view: { command: "pwd", steps: [{ text: "pwd" }] }, output: "[execute]\n/tmp" }])
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
        tools: [{ tool: "execute", params: 'command="sleep 9"', title: "sleep 9", view: { command: "sleep 9", steps: [{ text: "sleep 9" }] } }]
      )
    end

    it "gives an execute its view, the full command uncut, both storage shapes" do
      command = "cd /p/app && #{"rg -n foo lib | " * 8}head -5"
      native = described_class.for_message({ content: qwen_call("execute", command: command, cwd: "lib") }, [])
      chat = described_class.for_message({ content: "", tool_calls: [{ id: "c1", name: "task_create",
                                                                       arguments: { "command" => command } }] }, [])

      expect(native[:tools].first[:params].length).to be < command.length
      expect(native[:tools].first[:view]).to include(command: command, cwd: "lib", cd: "/p/app")
      expect(native[:tools].first[:view][:steps].last).to eq(text: "rg -n foo lib", op: "|", limit: "head 5")
      expect(chat[:tools].first[:view]).to eq(native[:tools].first[:view].except(:cwd))
    end

    it "titles a reloaded command by its description as the live row did, both storage shapes" do
      args = { command: "cd /p && ls | head -3 && pwd", description: "List the project" }
      native = described_class.for_message({ content: qwen_call("execute", **args) }, [])
      chat = described_class.for_message({ content: "", tool_calls: [{ id: "c1", name: "execute",
                                                                       arguments: args.transform_keys(&:to_s) }] }, [])

      [native, chat].each do |parts|
        expect(parts[:tools].first).to include(title: "List the project", params: 'command="cd /p && ls | head -3 && pwd"')
        expect(parts[:tools].first[:view]).to include(description: "List the project", cd: "/p")
      end
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
        tools: [{ tool: "execute", params: 'command="true"', title: "true", view: { command: "true", steps: [{ text: "true" }] }, output: "[execute]\n" },
                { tool: "read", params: 'path="README.md"', title: "README.md", output: "[read]\nhello" }]
      )
    end

    it "reads a Bridge snapshot's string keys" do
      message = { "role" => "model", "content" => "",
                  "tool_calls" => [{ "id" => "c1", "name" => "execute", "arguments" => { "command" => "echo hi" } }] }

      expect(described_class.for_message(message, [{ "content" => "[execute]\nhi", "tool_call_id" => "c1" }])).to eq(
        tools: [{ tool: "execute", params: 'command="echo hi"', title: "echo hi", view: { command: "echo hi", steps: [{ text: "echo hi" }] }, output: "[execute]\nhi" }]
      )
    end

    it "reads the reasoning the chat loop saved as thinking (trimmed), next to the calls" do
      message = { role: "model", content: "", thinking: "\nrun it first\n",
                  tool_calls: [{ id: "c1", name: "execute", arguments: { "command" => "true" } }] }

      expect(described_class.for_message(message, [{ content: "[execute]\n", tool_call_id: "c1" }])).to eq(
        thinking: "run it first", tools: [{ tool: "execute", params: 'command="true"', title: "true", view: { command: "true", steps: [{ text: "true" }] }, output: "[execute]\n" }]
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
      content = "#{qwen_call("read", path: "a.png")}#{qwen_call("execute", command: "true")}#{qwen_call("shots", {})}"
      response = { "content" => "[read]\nImage\n\n---\n\n[execute]\n\n\n---\n\n[shots]\ntwo",
                   "images" => [shot, gif, shot], "image_counts" => [1, 0, 2] }

      tools = described_class.for_message({ content: content }, [response])[:tools]
      expect(tools.map { |t| t[:images]&.map { |i| i[:name] } }).to eq([["shot.png"], nil, ["a.gif", "shot.png"]])
      expect(tools.first[:images]).to eq([shown])
    end

    it "native, an older session without image_counts: a lone call gets them, several get none" do
      one = described_class.for_message({ content: qwen_call("read", path: "a.png") }, [{ content: "[read]\nx", images: [shot] }])
      expect(one[:tools].first[:images]).to eq([shown])
      two = described_class.for_message({ content: "#{qwen_call("read", path: "a")}#{qwen_call("read", path: "b")}" },
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

  describe "titles" do
    it "gives each call its title, a path relative to the given cwd" do
      content = "#{qwen_call("execute", command: "cd /p/app && rspec")}#{qwen_call("edit", path: "/p/app/lib/a.rb", old_string: "a", new_string: "b")}"
      tools = described_class.for_message({ content: content }, [], cwd: "/p/app")[:tools]
      expect(tools.map { |t| t[:title] }).to eq(["rspec", "lib/a.rb"])
      expect(tools.first[:params]).to eq('command="cd /p/app && rspec"')
    end

    it "names a task_wait's task by its command from the session's task record" do
      Dir.mktmpdir do |cwd|
        dir = File.join(cwd, "tmp", "tasks", "t1")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "task.json"), JSON.generate("id" => "t1", "command" => "bundle exec rspec"))
        content = "#{qwen_call("task_wait", id: "t1", timeout: 300)}#{qwen_call("task_wait", id: "t2")}"
        tools = described_class.for_message({ content: content }, [], cwd: cwd)[:tools]
        expect(tools.map { |t| t[:title] }).to eq(["bundle exec rspec · up to 300s", nil])
        expect(tools.first[:params]).to eq('id="t1" timeout="300"')
      end
    end

    it "leaves the title out where there is none (a plugin tool)" do
      tools = described_class.for_message({ content: qwen_call("echo_args", text: "x") }, [], cwd: "/p")[:tools]
      expect(tools.first).not_to have_key(:title)
    end
  end

  describe "LLM context edits (the ✂ marks)" do
    def edit(kind, note, applied: true, staged_at: "s1", keep: nil)
      { "kind" => kind, "note" => note, "by" => kind == "stale" ? "chi" : "model", "staged_at" => staged_at,
        "applied_at" => applied ? "a1" : nil, "keep" => keep }.compact
    end

    let(:big) { "[read]\n#{"x" * 4000}" }
    let(:messages) do
      [{ role: "user", content: "go" },
       { role: "model", content: "", tool_calls: [{ id: "c1", name: "read", arguments: { "path" => "a.rb" } }] },
       { role: "tool_response", content: big, tool_call_id: "c1", tool_ids: ["t1"],
         edits: { t1: edit("stale", "a.rb: superseded by a later read") } },
       { role: "model", content: "", tool_calls: [{ id: "c2", name: "execute", arguments: { "command" => "ls" } },
                                                  { id: "c3", name: "read", arguments: { "path" => "b.rb" } }] },
       { role: "tool_response", content: "[execute]\nout", tool_call_id: "c2", tool_ids: ["t2"],
         edits: { "t2" => edit("forget", "ls shows 3 files") } },
       { role: "tool_response", content: "[read]\nb", tool_call_id: "c3", tool_ids: ["t3"],
         edits: { "t3" => edit("forget", "ls shows 3 files", keep: [[12, 40]]) } },
       { role: "model", content: "", tool_calls: [{ id: "c4", name: "execute", arguments: { "command" => "pwd" } }] },
       { role: "tool_response", content: "[execute]\n/p", tool_call_id: "c4", tool_ids: ["t4"],
         edits: { "t4" => edit("forget", "where we are", applied: false, staged_at: "s2") } }]
    end

    it "marks each edited output by id: a stale stub's reason, a forget call's note on its first output, staged ones" do
      expect(described_class.edit_marks(messages)).to eq(
        "t1" => { kind: "stale", note: "superseded by a later read" },
        "t2" => { kind: "forget", note: "ls shows 3 files" },
        "t3" => { kind: "forget", with: "t2", kept: "12-40" },
        "t4" => { kind: "forget", staged: true, note: "where we are" }
      )
    end

    it "gives a part its output's id and its mark; an applied stale stub says what it frees (its whole output)" do
      marks = described_class.edit_marks(messages)
      first = described_class.for_message(messages[1], [messages[2]], marks: marks)[:tools].first
      second = described_class.for_message(messages[3], messages[4..5], marks: marks)[:tools]

      expect(first).to include(tool_id: "t1", edit: { kind: "stale", note: "superseded by a later read", tokens: 1002 },
                               output_truncated: true)
      expect(second.map { |part| [part[:tool_id], part[:edit]] })
        .to eq([["t2", { kind: "forget", note: "ls shows 3 files" }], ["t3", { kind: "forget", with: "t2", kept: "12-40" }]])
    end

    [nil, "", "dup"].each do |id|
      it "pairs results by position when their tool_call_id is #{id.inspect} (omitted, empty or repeated)" do
        message = { role: "model", content: "", tool_calls: [{ id: id, name: "read", arguments: { "path" => "a.txt" } },
                                                             { id: id, name: "read", arguments: { "path" => "b.txt" } }] }
        responses = [{ role: "tool_response", content: "[read]\na", tool_call_id: id, tool_ids: ["t1"] },
                     { role: "tool_response", content: "[read]\nb", tool_call_id: id, tool_ids: ["t2"],
                       edits: { "t2" => edit("stale", "b.txt: superseded by a later read") } }]

        tools = described_class.for_message(message, responses, marks: described_class.edit_marks(responses))[:tools]

        expect(tools.map { |part| [part[:title], part[:output], part[:tool_id], part.key?(:edit)] })
          .to eq([["a.txt", "[read]\na", "t1", false], ["b.txt", "[read]\nb", "t2", true]])
      end
    end

    it "reads a native entry's ids by call, and string-keyed messages (a Bridge snapshot) the same" do
      content = "#{qwen_call("read", path: "a.rb")}#{qwen_call("execute", command: "ls")}"
      response = { "role" => "tool_response", "content" => "[read]\n#{"y" * 200}\n\n---\n\n[execute]\nz",
                   "tool_ids" => %w[t5 t6], "edits" => { "t6" => edit("forget", "nothing there") } }
      parts = described_class.for_message({ "role" => "model", "content" => content }, [response],
                                          marks: described_class.edit_marks([JSON.parse(JSON.generate(response))]))

      expect(parts[:tools].map { |part| [part[:tool_id], part[:edit]] })
        .to eq([["t5", nil], ["t6", { kind: "forget", note: "nothing there" }]])
    end
  end
end
