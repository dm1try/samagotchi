# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "samagotchi/tool_activity"
require "samagotchi/tools/builtins"
require "samagotchi/kernel_loop"
require "samagotchi/tool_runner"
require "samagotchi/turn_tally"

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

  it "labels forget_outputs as forgetting or restoring outputs, with its ids and note" do
    forget = Samagotchi::Tools::BuiltinCalls.build("forget_outputs", { "ids" => %w[t1 t2], "note" => "done" })
    restore = Samagotchi::Tools::BuiltinCalls.build("forget_outputs", { "restore" => ["t2"] })

    expect(described_class.tool_activity_event("forget_outputs", forget, "forgot t1, t2", registry: registry))
      .to include(action: "forgetting outputs", params: 'ids="t1,t2" note="done"', status: "ok")
    expect(described_class.tool_activity_event("forget_outputs", restore, "restored t2", registry: registry))
      .to include(action: "restoring outputs", params: 'restore="t2"')
  end

  it "carries an execute's description for the TUI's line, the params as they were" do
    call = { name: "execute", content: "ls | head -3", description: "List files." }
    expect(described_class.tool_activity_event("execute", call, "a", registry: registry))
      .to eq(action: "running command", tool: "execute", params: 'command="ls | head -3"', status: "ok",
             title: "List files", description: "List files")
    expect(described_class.tool_activity_event("execute", call.except(:description), "a", registry: registry))
      .not_to have_key(:description)
    expect(described_class.tool_activity_event("memory_write", { name: "memory_write", path: "n", description: "d" }, "ok",
                                               registry: registry)).not_to have_key(:description)
  end

  it "labels a memory_write with only a description as updating the description" do
    only = { name: "memory_write", path: "n", scope: "project", description: "OPEN: 1/2" }
    expect(described_class.tool_activity_event("memory_write", only, "ok", registry: registry)[:action])
      .to eq("updating memory description")
    expect(described_class.tool_activity_event("memory_write", only.merge(content: "x"), "ok", registry: registry)[:action])
      .to eq("saving memory")
    expect(described_class.tool_activity_action("memory_write")).to eq("saving memory")
  end

  it "labels a memory_write remove and shows remove=true" do
    call = { name: "memory_write", path: "handoff_x", scope: "project", remove: true }
    event = described_class.tool_activity_event("memory_write", call, "ok", registry: registry)
    expect(event[:action]).to eq("removing memory")
    expect(event[:params]).to eq('name="handoff_x" scope="project" remove=true')
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

    it "calls a command the user's Stop killed or kept from starting stopped, not an error" do
      killed = "Error: command stopped by the user after 3s (killed; rerun it if still needed)\nstdout:\nhalf\n"
      expect(described_class.tool_activity_status(killed, "execute")).to eq("stopped")
      expect(described_class.tool_activity_status(Samagotchi::Tools::Execute::NOT_RUN_ON_STOP, "execute")).to eq("stopped")
      expect(described_class.tool_activity_status(Samagotchi::Tools::Execute::NOT_RUN_ON_STOP, "task_create")).to eq("stopped")
      expect(described_class.tool_activity_status("Error: command timed out after 120s", "execute")).to eq("error")
      expect(described_class.tool_activity_status(killed, "read")).to eq("error")
    end

    it "calls a task_wait whose task was stopped (by the user or the model) stopped" do
      stopped = "task_id: t1\nstatus: stopped\nexit_code: \nstop_reason: stopped_by_user\noutput_path: x"
      expect(described_class.tool_activity_status(stopped, "task_wait")).to eq("stopped")
      expect(described_class.tool_activity_status(stopped.sub("stopped_by_user", "stopped_by_model"), "task_wait")).to eq("stopped")
      expect(described_class.tool_activity_status(stopped.sub("status: stopped", "status: completed"), "task_wait")).to eq("ok")
    end

    it "carries it into the activity event" do
      expect(described_class.tool_activity_event("execute", { name: "execute", content: "false" }, "exit: 1 (no output)")[:status])
        .to eq("error")
    end
  end

  describe ".no_match?" do
    none = "exit: 1 (no output)"
    {
      "grep -rn x spec/ 2>/dev/null | grep -i y" => [none, true],
      "rg -n foo lib/" => [none, true],
      "cd lib && rg foo" => [none, true],
      "LC_ALL=C /usr/bin/grep foo f" => [none, true],
      "pgrep -f nothing" => [none, true],
      "rg -c foo f" => ["stdout:\n0\nexit: 1", true],
      "rg -n a f | head -20 && rg -n b g" => [none, true],
      "ls missing && rg foo" => ["stderr:\nls: missing: No such file or directory\nexit: 1", false],
      "rg foo missing.rb" => ["stderr:\nrg: missing.rb: No such file\nexit: 2", false],
      "test -f x && grep foo x" => [none, false],
      "ls x 2>/dev/null && grep foo x" => [none, false],
      "grep -q foo a && grep bar b" => [none, false],
      "(cd x && grep a b)" => [none, false],
      "sed -n 1,5p f" => [none, false],
      "grep 'open quote f" => [none, false],
      "command -v rg >/dev/null 2>&1 && rg foo" => [none, false],
      "ls x >/dev/null 2>&1 && grep foo x" => [none, false],
      "ls x > /dev/null && grep foo x" => [none, false],
      "ls x &>/dev/null && grep f x" => [none, false],
      "sleep 1 & grep foo x" => [none, false],
      "test -f x || exit 1; grep x f" => [none, false],
      "[ -f x ] || return 1; grep x f" => [none, false],
      "set -e; [ -f x ]; grep x f" => [none, false],
      "set -euo pipefail; [ -f x ]; grep x f" => [none, false],
      "set -o errexit; [ -f x ]; grep x f" => [none, false],
      "type rg && rg foo" => [none, false],
      "hash rg && rg foo" => [none, false],
      "(( n > 0 )) && grep x f" => [none, false],
      "set -x; grep x f" => [none, true]
    }.each do |command, (result, expected)|
      it "says #{expected ? "no match" : "not a no-match"} for #{command}" do
        expect(described_class.no_match?(result, command)).to be(expected)
      end
    end

    it "is not a no-match without a command, or with exit 0" do
      expect(described_class.no_match?("exit: 1 (no output)", nil)).to be(false)
      expect(described_class.no_match?("exit: 0 (no output)", "rg foo")).to be(false)
    end

    it "keeps a no-match ok and flags it on the activity event" do
      event = described_class.tool_activity_event("execute", { name: "execute", content: "rg -n zzz lib/" }, "exit: 1 (no output)")
      expect(event).to include(status: "ok", no_match: true)
      expect(described_class.tool_activity_status("exit: 1 (no output)", "execute", command: "rg zzz")).to eq("ok")
    end

    it "keeps a real failure an error with no flag, and a grep with no command an error" do
      event = described_class.tool_activity_event("execute", { name: "execute", content: "sed -n 1p f" }, "exit: 1 (no output)")
      expect(event[:status]).to eq("error")
      expect(event).not_to have_key(:no_match)
      expect(described_class.tool_activity_status("exit: 1 (no output)", "execute")).to eq("error")
    end

    it "lets the server tally count only the real failure" do
      tally = Samagotchi::TurnTally.new
      [["rg zzz lib/", "exit: 1 (no output)"], ["sed -n 1p f", "stderr:\nsed: f: No such file\nexit: 1"],
       ["ls", "stdout:\na\nexit: 0"]]
        .each_with_index do |(command, result), i|
          tally.started(key: [1, i], tool: "execute", params: "command=x")
          tally.completed(key: [1, i], tool: "execute", params: "command=x",
                          status: described_class.tool_activity_status(result, "execute", command: command))
        end
      expect(tally.text).to include("(1 failed)")
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

    it "gives a command's description in place of its steps, cut to a title" do
      expect(title("execute", content: "cd /x && rg -n foo | head -3 && ls", description: "Find foo uses.")).to eq("Find foo uses")
      expect(title("execute", content: "ls && pwd", description: "  ")).to eq("ls +1")
      expect(title("execute", content: "ls", description: "a " * 40).length).to be <= Samagotchi::ToolView::TITLE_LIMIT
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

    describe "for the task tools" do
      let(:root) { Dir.mktmpdir }

      after { FileUtils.rm_rf(root) }

      def task(id, command)
        dir = File.join(root, "tmp", "tasks", id)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "task.json"), JSON.generate("id" => id, "command" => command))
      end

      it "names a task_wait's task by its command (its leading cd gone) and how long it waits" do
        task("20261004-ab12", "cd /p/app && bundle exec parallel_rspec -n 8 spec")
        expect(title("task_wait", cwd: root, content: "20261004-ab12", timeout: "120")).to eq("bundle exec parallel_rspec -n 8 spec · up to 120s")
        expect(title("task_wait", cwd: root, content: " 20261004-ab12 ")).to eq("bundle exec parallel_rspec -n 8 spec · up to 600s")
      end

      it "names a task_get's and a task_stop's task by its command" do
        task("t1", "npm test && npm run e2e")
        expect(title("task_get", cwd: root, content: "t1")).to eq("npm test +1")
        expect(title("task_stop", cwd: root, content: "t1")).to eq("npm test +1")
      end

      it "cuts a long command so the wait still fits 80" do
        task("t1", "y" * 100)
        cut = title("task_wait", cwd: root, content: "t1", timeout: "600")
        expect(cut).to eq("#{"y" * 66}… · up to 600s")
        expect(cut.length).to eq(80)
      end

      it "has none (the row keeps its id) for a missing, unreadable or odd task" do
        expect(title("task_wait", cwd: root, content: "nope")).to be_nil
        dir = File.join(root, "tmp", "tasks", "bad")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "task.json"), "{not json")
        expect(title("task_get", cwd: root, content: "bad")).to be_nil
        task("blank", "  ")
        expect(title("task_get", cwd: root, content: "blank")).to be_nil
        task("t1", "ls")
        expect(title("task_get", cwd: File.join(root, "tmp", "tasks", "x"), content: "../t1")).to be_nil
        expect(title("task_wait", cwd: root, content: "")).to be_nil
      end

      it "reads the process's directory when no cwd is given" do
        task("t1", "make")
        Dir.chdir(root) { expect(title("task_get", cwd: nil, content: "t1")).to eq("make") }
      end
    end

    it "rides on the completed activity when there is one (cwd: the process's)" do
      event = described_class.tool_activity_event("execute", { name: "execute", content: "cd /x && ls" }, "ok")
      expect(event[:title]).to eq("ls")
      expect(described_class.tool_activity_event("task_list", { name: "task_list" }, "ok")).not_to have_key(:title)
    end
  end
end
