# frozen_string_literal: true

require "spec_helper"
require "samagotchi/tool_activity"
require "samagotchi/tools/builtins"
require "samagotchi/kernel_loop"
require "samagotchi/tool_runner"

RSpec.describe Samagotchi::ToolActivity do
  let(:schema) { { name: "jira_search", description: "d", parameters: { type: "object", properties: {}, required: [] } } }

  def registry(**entry)
    Samagotchi::Tools::Builtins.registry.tap do |registry|
      registry.register("jira_search", schema: schema, handler: ->(_call, _kctx) { "3 issues" }, source: "spec", **entry)
    end
  end

  it "keeps the built-ins' own words, with or without a registry" do
    call = { name: "read", content: "lib/a.rb" }
    [nil, registry].each do |tools|
      expect(described_class.tool_activity_event("read", call, "ok", registry: tools))
        .to eq(action: "reading file", tool: "read", params: 'path="lib/a.rb"', status: "ok", title: "lib/a.rb")
      expect(described_class.tool_activity_event("register_reminder", { name: "register_reminder", content: "x" }, "ok",
                                                 registry: tools))
        .to include(action: "calling tool", params: nil)
    end
  end

  it "says calling tool with no params for a tool the registry doesn't know" do
    expect(described_class.tool_activity_event("nope", { name: "nope", content: "x" }, "Error: …", registry: registry))
      .to eq(action: "calling tool", tool: "nope", params: nil, status: "error")
  end

  it "uses a registry tool's label and preview" do
    tools = registry(label: "searching Jira", preview: ->(call) { "q=#{call[:query]}" })
    expect(described_class.tool_activity_event("jira_search", { name: "jira_search", query: "bug" }, "3", registry: tools))
      .to include(action: "searching Jira", params: "q=bug")
  end

  it "falls back to calling tool and the given arguments as key=value" do
    call = { name: "jira_search", query: "open bugs", limit: 5, project: "" }
    expect(described_class.tool_activity_event("jira_search", call, "3", registry: registry))
      .to include(action: "calling tool", params: 'query="open bugs" limit="5"')
  end

  it "takes the parsers' args: when the call has them, a list or object as JSON" do
    call = { name: "jira_search", content: "raw", args: { "query" => "bug", "labels" => ["a"], "opts" => { "x" => 1 } } }
    expect(described_class.tool_activity_params("jira_search", call, registry: registry))
      .to eq('query="bug" labels="[\\"a\\"]" opts="{\\"x\\":1}"')
  end

  it "falls back to key=value when the preview raises" do
    tools = registry(preview: ->(_call) { raise "boom" })
    call = { name: "jira_search", args: { "query" => "bug" } }
    expect(described_class.tool_activity_params("jira_search", call, registry: tools)).to eq('query="bug"')
  end

  it "reaches the tool_call_started params (the spinner) and the completed activity through ToolRunner" do
    kernel = Samagotchi::KernelLoop.new(client: instance_double(Samagotchi::Client), profile: :gemma4)
    kernel.tools = registry
    events = []
    Samagotchi::ToolRunner.new(kernel).run({ name: "jira_search", query: "bug" }, iteration: 1, call_index: 1, call_count: 1,
                                           on_stream_event: ->(event) { events << event }, max_tool_output_chars: nil)
    expect(events.find { |e| e[:type] == :tool_call_started }[:params]).to eq('query="bug"')
    expect(events.find { |e| e[:type] == :tool_call_completed }[:activity]).to include(params: 'query="bug"', status: "ok")
  end

  describe "status" do
    it "counts an execute that exited non-zero as an error" do
      expect(described_class.tool_activity_status("stderr:\nls: /nonexistent: No such file\nexit: 1", "execute")).to eq("error")
      expect(described_class.tool_activity_status("exit: 2 (no output)", "execute")).to eq("error")
      expect(described_class.tool_activity_status("stdout:\nkilled\nexit: ", "execute")).to eq("error")
    end

    it "keeps exit 0, other tools' text and results without an exit line ok" do
      expect(described_class.tool_activity_status("stdout:\nexit: 1\nexit: 0", "execute")).to eq("ok")
      expect(described_class.tool_activity_status("exit: 0 (no output)", "execute")).to eq("ok")
      expect(described_class.tool_activity_status("exit: 1", "read")).to eq("ok")
      expect(described_class.tool_activity_status("done", "execute")).to eq("ok")
      expect(described_class.tool_activity_status("Error: cwd not found: /x", "execute")).to eq("error")
    end

    it "calls a task_wait the user's Stop ended stopped, not ok" do
      canceled = "task_id: t1\nstatus: running\nwait_result: canceled\nnote: the user stopped the turn while waiting\noutput_tail:"
      expect(described_class.tool_activity_status(canceled, "task_wait")).to eq("stopped")
      expect(described_class.tool_activity_status(canceled.sub("canceled", "timeout"), "task_wait")).to eq("ok")
      expect(described_class.tool_activity_status("wait_result: canceled", "read")).to eq("ok")
    end

    it "carries it into the activity event" do
      expect(described_class.tool_activity_event("execute", { name: "execute", content: "false" }, "exit: 1 (no output)")[:status])
        .to eq("error")
    end
  end

  describe ".tool_title" do
    def title(name, cwd: "/p/samagotchi", **call) = described_class.tool_title(name, { name: name }.merge(call), cwd: cwd)

    it "gives a file tool's path relative to the cwd when it is under it" do
      expect(title("read", content: "/p/samagotchi/lib/a.rb")).to eq("lib/a.rb")
      expect(title("edit", path: "/p/samagotchi/lib/b.rb", start_line: 3)).to eq("lib/b.rb")
      expect(title("write", path: "/p/samagotchi/./c.rb")).to eq("c.rb")
      expect(title("read", content: "lib/rel.rb")).to eq("lib/rel.rb")
    end

    it "keeps a path outside the cwd absolute, a sibling with a shared prefix too" do
      expect(title("read", content: "/p/samagotchi-stage/lib/a.rb")).to eq("/p/samagotchi-stage/lib/a.rb")
      expect(title("read", content: "/etc/hosts")).to eq("/etc/hosts")
      expect(title("read", content: "/p/samagotchi")).to eq("/p/samagotchi")
      expect(title("read", content: "/p/samagotchi/a.rb", cwd: nil)).to eq("/p/samagotchi/a.rb")
    end

    it "cuts a long path from the front, so the file name stays" do
      long = "/x/#{"d" * 90}/file.rb"
      cut = title("read", content: long)
      expect(cut.length).to eq(80)
      expect(cut).to start_with("…").and end_with("/file.rb")
    end

    it "gives a command's first step and how many more, its leading cd dropped" do
      expect(title("execute", content: "cd /x && rspec a")).to eq("rspec a")
      expect(title("execute", content: "cd /x; ls")).to eq("ls")
      expect(title("execute", content: "cd '/my dir' && make")).to eq("make")
      expect(title("execute", content: "\n  git status\ngit diff")).to eq("git status +1")
      expect(title("task_create", content: "cd /x && npm test")).to eq("npm test")
      expect(title("execute", content: "echo cd /x && ls")).to eq("echo cd /x +1")
      expect(title("execute", content: "cd /p && a | head -5; b; c | tail -2; d && e || f")).to eq("a +5")
    end

    it "doesn't count a label echo or a limit as a step" do
      expect(title("execute", content: %(cd /p && echo "=== log ===" && git log | head -20 && echo "=== diff ===" && git diff)))
        .to eq("git log +1")
    end

    it "shows a heredoc command's first line, the body not" do
      expect(title("execute", content: "git commit -m \"$(cat <<'EOF'\nFix\n\nbody\nEOF\n)\" && git log -1"))
        .to eq(%(git commit -m "$(cat <<'EOF')" +1))
    end

    it "cuts the first step to fit 80 with its +N" do
      expect(title("execute", content: "cd /somewhere && #{"y" * 100}")).to eq("#{"y" * 79}…")
      cut = title("execute", content: "#{"y" * 100} && a && b")
      expect(cut).to eq("#{"y" * 76}… +2")
      expect(cut.length).to eq(80)
    end

    it "falls back to the first line without its cd when the command has no steps" do
      expect(title("execute", content: "cd /x && for f in *; do echo $f; done")).to eq("for f in *; do echo $f; done")
      expect(title("execute", content: "echo 'open\nsecond")).to eq("echo 'open")
    end

    it "names the memory for the memory tools, nil for the rest" do
      expect(title("memory_write", path: "notes/todo")).to eq("notes/todo")
      expect(title("memory_read", content: "todo")).to eq("todo")
      expect(title("memory_read", content: "")).to be_nil
      expect(title("task_list")).to be_nil
      expect(title("jira_search", query: "x")).to be_nil
      expect(title("read", content: "  ")).to be_nil
    end

    it "rides on the completed activity when there is one (cwd: the process's)" do
      event = described_class.tool_activity_event("execute", { name: "execute", content: "cd /x && ls" }, "ok")
      expect(event[:title]).to eq("ls")
      expect(described_class.tool_activity_event("task_list", { name: "task_list" }, "ok")).not_to have_key(:title)
    end
  end
end
