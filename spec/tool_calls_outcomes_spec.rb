# frozen_string_literal: true

require "tmpdir"
require "samagotchi/kernel_loop"
require "samagotchi/reminder_store"
require "samagotchi/tool_call_parser"
require "samagotchi/llm/openai_chat"
require "samagotchi/llm/native_tool_normalizer"
require "samagotchi/web/message_parts"

# What a built call does once it runs, per model format, for the cases the
# three mappers disagree on; and what a reloaded session shows for one.
# The builds themselves are in tool_calls_characterization_spec.rb.
RSpec.describe "Tool call outcomes per model format" do
  delim = '<|"|>'
  gemma = Samagotchi::ToolCallParser::Gemma.new(Samagotchi::ModelProfile.gemma4)
  qwen = Samagotchi::ToolCallParser::Qwen.new(Samagotchi::ModelProfile.qwen36)

  define_method(:qwen_wire) do |name, args|
    "<tool_call>\n<function=#{name}>\n#{args.map { |k, v| "<parameter=#{k}>\n#{v}\n</parameter>\n" }.join}</function>\n</tool_call>"
  end
  define_method(:gemma_wire) do |name, args|
    "<|tool_call>call:#{name}{#{args.map { |k, v| "#{k}:#{delim}#{v}#{delim}" }.join(',')}}<tool_call|>"
  end
  define_method(:built) do |format, name, args|
    case format
    when :gemma then gemma.parse(gemma_wire(name, args)).first
    when :qwen then qwen.parse(qwen_wire(name, args)).first
    when :chat
      Samagotchi::LLM::NativeToolNormalizer.normalize(Samagotchi::LLM::ToolCall.new(id: "c1", name: name, arguments: args))
    end
  end

  let(:dir) { Dir.mktmpdir("tool-call-outcomes") }
  let(:file) { File.join(dir, "a.txt").tap { |path| File.write(path, "keep x</old>y me\n") } }
  let(:store) { Samagotchi::ReminderStore.new }
  let(:kernel) { Samagotchi::KernelLoop.new(client: nil, reminder_store: store) }

  after { FileUtils.rm_rf(dir) }

  def run(call) = kernel.dispatch_tool_call(call)[:output].sub(dir, "DIR")

  # [format, output, file after]
  {
    "write without content" => [
      ["write", ->(f) { { "path" => f } }],
      { gemma: ["[write]\nError: missing content", "keep x</old>y me\n"],
        qwen: ["[write]\nError: missing content", "keep x</old>y me\n"],
        chat: ["[write]\nError: missing content", "keep x</old>y me\n"] }
    ],
    "edit without new_text" => [
      ["edit", ->(f) { { "path" => f, "old_text" => "keep" } }],
      { gemma: ["[edit]\nEdited DIR/a.txt: replaced 4 bytes with 0 bytes", " x</old>y me\n"],
        qwen: ["[edit]\nEdited DIR/a.txt: replaced 4 bytes with 0 bytes", " x</old>y me\n"],
        chat: ["[edit]\nEdited DIR/a.txt: replaced 4 bytes with 0 bytes", " x</old>y me\n"] }
    ],
    "edit whose old text holds </old>" => [
      ["edit", ->(f) { { "path" => f, "old_text" => "x</old>y", "new_text" => "z" } }],
      { gemma: ["[edit]\nEdited DIR/a.txt: replaced 1 bytes with 1 bytes", "keep z</old>y me\n"],
        qwen: ["[edit]\nEdited DIR/a.txt: replaced 1 bytes with 1 bytes", "keep z</old>y me\n"],
        chat: ["[edit]\nEdited DIR/a.txt: replaced 1 bytes with 1 bytes", "keep z</old>y me\n"] }
    ]
  }.each do |label, ((tool, args), outcomes)|
    outcomes.each do |format, (output, after)|
      it "#{format}: #{label}" do
        expect(run(built(format, tool, args.call(file)))).to eq(output)
        expect(File.read(file)).to eq(after)
      end
    end
  end

  # [output, intervals registered]
  {
    gemma: ["[register_reminder]\nReminder 'r' registered (interval: 1m, id: ID).", [1]],
    qwen: ["[register_reminder]\nReminder 'r' registered (interval: 1m, id: ID).", [1]],
    chat: ["[register_reminder]\nReminder 'r' registered (interval: 1m, id: ID).", [1]]
  }.each do |format, (output, intervals)|
    it "#{format}: register_reminder without an interval" do
      call = built(format, "register_reminder", { "name" => "r", "description" => "d" })
      expect(run(call).sub(/id: \w+/, "id: ID")).to eq(output)
      expect(store.reminders.values.map { |r| r[:interval_minutes] }).to eq(intervals)
    end
  end

  describe "a reloaded session's rows (web message parts)" do
    let(:tools) do
      [["execute", { "command" => "ls", "cwd" => "web" }], ["edit", { "path" => "a.rb", "old_text" => "a", "new_text" => "b" }],
       ["echo_args", { "text" => "hi" }]]
    end
    let(:outputs) { ["[execute]\nok", "[edit]\nEdited", "[echo_args]\nhi"] }
    let(:rows) do
      { tools: [{ tool: "execute", params: 'command="ls"', title: "ls", output: "[execute]\nok" },
                { tool: "edit", params: 'path="a.rb"', title: "a.rb", output: "[edit]\nEdited" },
                { tool: "echo_args", params: 'text="hi"', output: "[echo_args]\nhi" }] }
    end
    let(:joined) { { role: "tool_response", content: outputs.join("\n\n---\n\n") } }

    it "reads Qwen markup" do
      content = tools.map { |name, args| qwen_wire(name, args) }.join
      expect(Samagotchi::Web::MessageParts.for_message({ role: "model", content: content }, [joined])).to eq(rows)
    end

    it "reads Gemma markup" do
      content = tools.map { |name, args| gemma_wire(name, args) }.join
      expect(Samagotchi::Web::MessageParts.for_message({ role: "model", content: content }, [joined])).to eq(rows)
    end

    it "reads the chat loop's saved arguments" do
      message = { role: "model", content: "",
                  tool_calls: tools.each_with_index.map { |(name, args), i| { id: i.to_s, name: name, arguments: args } } }
      responses = outputs.each_with_index.map { |output, i| { role: "tool_response", tool_call_id: i.to_s, content: output } }
      expect(Samagotchi::Web::MessageParts.for_message(message, responses)).to eq(rows)
    end
  end
end
