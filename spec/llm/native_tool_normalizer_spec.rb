# frozen_string_literal: true

require "samagotchi/llm/backend"
require "samagotchi/llm/native_tool_normalizer"
require "samagotchi/llm/openai_chat"
require "samagotchi/kernel_loop"
require "samagotchi/reminder_store"

RSpec.describe Samagotchi::LLM::NativeToolNormalizer do
  # The chat loop hands over LLM::ToolCall values (arguments parsed).
  def tool_call(name:, arguments: {})
    Samagotchi::LLM::ToolCall.new(id: "call_#{name}", name: name, arguments: arguments)
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

    it "maps an Edit call: old and new text as their own fields" do
      call = tool_call(name: "edit", arguments: {
        "path" => "lib/foo.rb",
        "old_text" => "a",
        "new_text" => "b"
      })
      mapped = described_class.normalize(call)

      expect(mapped[:name]).to eq("edit")
      expect(mapped).to include(content: "", old_text: "a", new_text: "b")
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

    it "maps send_note's session and text" do
      mapped = described_class.normalize(tool_call(name: "send_note", arguments: { "session" => "3f2a1c", "text" => "moved" }))
      expect(mapped).to include(name: "send_note", content: "moved", session: "3f2a1c")
    end

    it "maps delegate's task and options, and delegate_result's session" do
      mapped = described_class.normalize(tool_call(name: "delegate", arguments: { "task" => "count", "model" => "tiny", "wait" => false, "timeout" => 30 }))
      expect(mapped).to include(name: "delegate", content: "count", model: "tiny", session: nil, wait: false, timeout: 30)
      expect(described_class.normalize(tool_call(name: "delegate_result", arguments: { "session" => "3f2a1c" })))
        .to include(name: "delegate_result", content: "", session: "3f2a1c", timeout: nil)
    end

    it "maps list_sessions with an optional folder" do
      expect(described_class.normalize(tool_call(name: "list_sessions", arguments: {}))).to include(name: "list_sessions", cwd: nil)
      expect(described_class.normalize(tool_call(name: "list_sessions", arguments: { "cwd" => "/w" }))).to include(cwd: "/w")
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

    # 7c: these used to pass through, losing description and interval_minutes.
    it "maps register_reminder: the name is the content, description and interval are kept" do
      call = tool_call(name: "register_reminder",
                       arguments: { "name" => "api_health", "description" => "check the API", "interval_minutes" => 15 })
      mapped = described_class.normalize(call)

      expect(mapped).to include(name: "register_reminder", content: "api_health",
                                description: "check the API", interval_minutes: 15)
    end

    it "maps cancel_reminder and list_reminders" do
      expect(described_class.normalize(tool_call(name: "cancel_reminder", arguments: { "name" => "api_health" })))
        .to include(name: "cancel_reminder", content: "api_health")
      expect(described_class.normalize(tool_call(name: "list_reminders")))
        .to include(name: "list_reminders", content: "")
    end

    it "registers a real reminder end to end through KernelLoop#dispatch" do
      store = Samagotchi::ReminderStore.new
      kernel = Samagotchi::KernelLoop.new(client: double("client"), reminder_store: store)
      call = tool_call(name: "register_reminder",
                       arguments: { "name" => "api_health", "description" => "check the API", "interval_minutes" => 15 })

      result = kernel.dispatch_tool_call(described_class.normalize(call))

      expect(result[:output]).not_to include("Error")
      expect(store.reminders.values).to contain_exactly(
        include(name: "api_health", description: "check the API", interval_minutes: 15)
      )
    end

    it "passes an unknown tool name through unchanged so dispatch renders the standard error" do
      call = tool_call(name: "frobnicate", arguments: { "x" => "1" })
      mapped = described_class.normalize(call)

      expect(mapped[:name]).to eq("frobnicate")
      expect(mapped[:path]).to be_nil
      expect(mapped[:scope]).to be_nil
      expect(mapped[:args]).to eq("x" => "1")
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
