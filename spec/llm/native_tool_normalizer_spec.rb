# frozen_string_literal: true

require "samagotchi/llm/backend"
require "samagotchi/llm/native_tool_normalizer"

RSpec.describe Samagotchi::LLM::NativeToolNormalizer do
  # A gem RubyLLM::ToolCall is {id:, name:, arguments: <Hash>}. We stand in for it
  # with a double so the spec never touches the gem's network parsing.
  def tool_call(name:, arguments: {})
    double(id: "call_#{name}", name: name, arguments: arguments)
  end

  describe ".normalize" do
    it "maps an Execute call: content is the command blob" do
      call = tool_call(name: "execute", arguments: { "command" => "echo hello" })
      mapped = described_class.normalize(call)

      expect(mapped[:name]).to eq("execute")
      expect(mapped[:content]).to eq("echo hello")
      expect(mapped[:path]).to be_nil
      expect(mapped[:scope]).to be_nil
    end

    it "maps a Read call, preserving path and line range" do
      call = tool_call(name: "read", arguments: { "path" => "spec/x_spec.rb", "start_line" => "10", "end_line" => "20" })
      mapped = described_class.normalize(call)

      expect(mapped[:name]).to eq("read")
      expect(mapped[:content]).to eq("spec/x_spec.rb")
      expect(mapped[:start_line]).to eq("10")
      expect(mapped[:end_line]).to eq("20")
    end

    it "reconstructs the Edit content blob (<old>..</old><new>..</new>) from structured args" do
      call = tool_call(name: "edit", arguments: {
        "path" => "lib/foo.rb",
        "old_text" => "a",
        "new_text" => "b"
      })
      mapped = described_class.normalize(call)

      expect(mapped[:name]).to eq("edit")
      expect(mapped[:content]).to eq("<old>a</old><new>b</new>")
      expect(mapped[:path]).to eq("lib/foo.rb")
    end

    it "maps a Write call, accepting content or text" do
      call = tool_call(name: "write", arguments: { "path" => "out.txt", "text" => "hi" })
      mapped = described_class.normalize(call)

      expect(mapped[:name]).to eq("write")
      expect(mapped[:content]).to eq("hi")
      expect(mapped[:path]).to eq("out.txt")
    end

    it "maps a MemoryRead call to content+scope" do
      call = tool_call(name: "memory_read", arguments: { "name" => "identity", "scope" => "system" })
      mapped = described_class.normalize(call)

      expect(mapped[:name]).to eq("memory_read")
      expect(mapped[:content]).to eq("identity")
      expect(mapped[:scope]).to eq("system")
    end

    it "maps a MemoryWrite call, preferring content then text/body and carrying description" do
      call = tool_call(name: "memory_write", arguments: {
        "name" => "foo", "content" => "bar", "scope" => "project", "description" => "desc"
      })
      mapped = described_class.normalize(call)

      expect(mapped[:name]).to eq("memory_write")
      expect(mapped[:content]).to eq("bar")
      expect(mapped[:path]).to eq("foo")
      expect(mapped[:scope]).to eq("project")
      expect(mapped[:description]).to eq("desc")
    end

    it "maps a WebFetch call" do
      call = tool_call(name: "web_fetch", arguments: { "url" => "https://example.com" })
      mapped = described_class.normalize(call)

      expect(mapped[:name]).to eq("web_fetch")
      expect(mapped[:content]).to eq("https://example.com")
    end

    it "maps a TaskCreate call with cwd/env" do
      call = tool_call(name: "task_create", arguments: { "command" => "rspec", "cwd" => "/tmp" })
      mapped = described_class.normalize(call)

      expect(mapped[:name]).to eq("task_create")
      expect(mapped[:content]).to eq("rspec")
      expect(mapped[:cwd]).to eq("/tmp")
    end

    it "maps a TaskGet call" do
      call = tool_call(name: "task_get", arguments: { "id" => "abc123" })
      mapped = described_class.normalize(call)

      expect(mapped[:name]).to eq("task_get")
      expect(mapped[:content]).to eq("abc123")
    end

    it "maps a TaskList call (no args needed)" do
      mapped = described_class.normalize(tool_call(name: "task_list", arguments: {}))
      expect(mapped[:name]).to eq("task_list")
      expect(mapped[:content]).to eq("")
    end

    it "maps a TaskWait call, carrying timeout/tail_lines/done_pattern" do
      call = tool_call(name: "task_wait", arguments: { "id" => "x", "timeout" => "5", "done_pattern" => "done" })
      mapped = described_class.normalize(call)

      expect(mapped[:name]).to eq("task_wait")
      expect(mapped[:timeout]).to eq("5")
      expect(mapped[:done_pattern]).to eq("done")
    end

    it "passes an unknown tool name through unchanged so dispatch renders the standard error" do
      call = tool_call(name: "frobnicate", arguments: { "x" => "1" })
      mapped = described_class.normalize(call)

      expect(mapped[:name]).to eq("frobnicate")
      expect(mapped[:path]).to be_nil
      expect(mapped[:scope]).to be_nil
    end

    it "defensively handles a nil arguments (no raise)" do
      mapped = described_class.normalize(tool_call(name: "execute", arguments: nil))
      expect(mapped[:name]).to eq("execute")
      expect(mapped[:content]).to eq("")
    end

    it "defensively handles a JSON-string arguments (parses to a Hash)" do
      call = double(id: "c", name: "execute", arguments: '{"command":"echo hi"}')
      mapped = described_class.normalize(call)
      expect(mapped[:content]).to eq("echo hi")
    end
  end

  describe ".normalize_all" do
    it "maps an array and drops nils" do
      mapped = described_class.normalize_all([
        tool_call(name: "execute", arguments: { "command" => "a" }),
        nil,
        tool_call(name: "web_fetch", arguments: { "url" => "https://x" })
      ])
      expect(mapped.map { |m| m[:name] }).to eq(%w[execute web_fetch])
    end
  end
end
