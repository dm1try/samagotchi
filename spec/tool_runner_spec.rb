# frozen_string_literal: true

require "samagotchi/tool_runner"
require "samagotchi/hooks"
require "samagotchi/tools/builtins"
require "samagotchi/tools/edit"
require "samagotchi/tools/write"
require "tmpdir"

# ToolRunner's per-call contract around the before_tool_call veto. The loop
# level (text the model gets, both loops) is in
# spec/llm/tool_call_wrapper_parity_spec.rb.
RSpec.describe Samagotchi::ToolRunner do
  let(:hooks) { Samagotchi::Hooks::Registry.new }
  let(:dispatched) { [] }
  let(:kernel) do
    k = Struct.new(:hooks, :dispatched) do
      def dispatch_tool_call(call)
        dispatched << call
        { output: "[#{call[:name]}]\nran", activity: { tool: call[:name], status: "ok" } }
      end
    end
    k.new(hooks, dispatched)
  end
  let(:events) { [] }
  let(:runner) { described_class.new(kernel) }
  let(:call) { { name: "execute", content: "ls" } }

  def run(c = call)
    runner.run(c, iteration: 1, call_index: 1, call_count: 1,
                  on_stream_event: ->(e) { events << e }, max_tool_output_chars: nil)
  end

  it "dispatches an unvetoed call; nothing waited, so no waited_ms" do
    run
    expect(events.last).not_to have_key(:waited_ms)
  end

  it "dispatches an unvetoed call" do
    result = run
    expect(result[:output]).to eq("[execute]\nran")
    expect(dispatched).to eq([call])
  end

  it "does not dispatch a blocked call and gives the model the veto text" do
    hooks.register(:before_tool_call) { |e| e[:blocked] = true; e[:block_reason] = "nope" }
    result = run
    expect(dispatched).to be_empty
    expect(result[:output]).to eq("[execute] Error: blocked by guardrail: nope")
    expect(result[:activity]).to include(status: "blocked")
  end

  it "uses a default reason when a hook blocks without one" do
    hooks.register(:before_tool_call) { |e| e[:blocked] = true }
    expect(run[:output]).to eq("[execute] Error: blocked by guardrail: blocked by hook")
  end

  it "dispatches a call a hook replaced" do
    hooks.register(:before_tool_call) { |e| e[:call] = { name: "execute", content: "pwd" } }
    run
    expect(dispatched).to eq([{ name: "execute", content: "pwd" }])
  end

  it "passes the before event its call, params, and an unset veto" do
    seen = nil
    hooks.register(:before_tool_call) { |e| seen = e.dup }
    run
    expect(seen).to include(type: :before_tool_call, iteration: 1, call: call, blocked: false, block_reason: nil)
    expect(seen[:params]).to include("ls")
  end

  it "still dispatches when a hook raises" do
    hooks.register(:before_tool_call) { |_e| raise "boom" }
    run
    expect(dispatched).to eq([call])
  end

  describe "sticky verdict" do
    it "keeps a veto a later hook tries to undo" do
      hooks.register(:before_tool_call) { |e| e[:blocked] = true; e[:block_reason] = "nope" }
      hooks.register(:before_tool_call) { |e| e[:blocked] = false; e[:block_reason] = nil }
      result = run
      expect(dispatched).to be_empty
      expect(result[:output]).to eq("[execute] Error: blocked by guardrail: nope")
    end

    it "denies through the verdict API with the deny text for the model" do
      hooks.register(:before_tool_call) { |e| e[:guardrail].deny!("no listing today") }
      result = run
      expect(dispatched).to be_empty
      expect(result[:output]).to eq(
        "[execute] Error: denied by guardrail (hook): no listing today. The user was not asked. " \
        "Do not retry it or reach the same result another way; ask the user how to proceed."
      )
      expect(result[:activity]).to include(status: "blocked", guardrail: { verdict: "deny", decided_by: "hook" })
    end

    it "ends the deny text with the voter's advice instead of the fixed tail" do
      hooks.register(:before_tool_call) do |e|
        e[:guardrail].deny!('"dedvo" is 1 edit away from "dedov"', source: "hook known_names, bundle known-names",
                            advice: 'Retry with "dedov".')
      end
      expect(run[:output]).to eq(
        '[execute] Error: denied by guardrail (hook known_names, bundle known-names): "dedvo" is 1 edit away from "dedov". ' \
        'The user was not asked. Retry with "dedov".'
      )
    end

    it "keeps the fixed tail when the advice is blank, and the first vote's advice when a later deny loses" do
      hooks.register(:before_tool_call) { |e| e[:guardrail].deny!("no", advice: " ") }
      expect(run[:output]).to end_with("Do not retry it or reach the same result another way; ask the user how to proceed.")

      hooks.unregister(:before_tool_call)
      hooks.register(:before_tool_call) { |e| e[:guardrail].deny!("first", advice: "Retry it corrected.") }
      hooks.register(:before_tool_call) { |e| e[:guardrail].deny!("second", advice: "Other advice.") }
      expect(run[:output]).to eq("[execute] Error: denied by guardrail (hook): first. The user was not asked. Retry it corrected.")
    end

    it "names the rule and its source in the deny text" do
      hooks.register(:before_tool_call) { |e| e[:guardrail].deny!("pushes commits", rule: "git-push", source: "bundle guardrails") }
      expect(run[:output]).to start_with("[execute] Error: denied by guardrail (rule git-push, bundle guardrails): pushes commits.")
    end

    it "denies an ask when no one can approve it" do
      hooks.register(:before_tool_call) { |e| e[:guardrail].ask!("really?") }
      result = run
      expect(dispatched).to be_empty
      expect(result[:output]).to include("denied by guardrail (hook): really? No one to approve it.")
    end

    it "lets hooks see the verdict so far" do
      seen = nil
      hooks.register(:before_tool_call) { |e| e[:guardrail].deny!("x") }
      hooks.register(:before_tool_call) { |e| seen = [e[:guardrail].decision, e[:blocked]] }
      run
      expect(seen).to eq([:deny, true])
    end
  end

  it "denies the call when the gate itself fails" do
    allow_any_instance_of(Samagotchi::Guardrails::Gate).to receive(:evaluate).and_raise(RuntimeError, "bug")
    result = run
    expect(dispatched).to be_empty
    expect(result[:output]).to start_with("[execute] Error: denied by guardrail (core): the guardrail check failed: RuntimeError: bug.")
  end

  describe "tool_call_started" do
    it "is emitted after the hooks, with the call they replaced" do
      order = []
      hooks.register(:before_tool_call) do |e|
        order << (events.any? { |ev| ev[:type] == :tool_call_started } ? :started_before : :started_after)
        e[:call] = { name: "execute", content: "pwd" }
      end
      run
      expect(order).to eq([:started_after])
      expect(events.first).to include(type: :tool_call_started, call: { name: "execute", content: "pwd" })
      expect(events.first[:params]).to include("pwd")
    end

    it "carries a plugin tool's label, and the run returns it to save with the result" do
      registry = Samagotchi::Tools::Builtins.registry
      registry.register("mcp_chrome_screenshot", schema: { parameters: { properties: {} } }, handler: ->(*) { "ok" },
                                                 source: "mcp", label: "chrome: screenshot")
      labelled = Struct.new(:hooks, :tools) do
        def dispatch_tool_call(call) = { output: "[#{call[:name]}]\nok", activity: { tool: call[:name], status: "ok" } }
      end.new(hooks, registry)
      result = described_class.new(labelled).run({ name: "mcp_chrome_screenshot" }, iteration: 1, call_index: 1, call_count: 1,
                                                 on_stream_event: ->(e) { events << e }, max_tool_output_chars: nil)
      expect(events.first).to include(type: :tool_call_started, tool: "mcp_chrome_screenshot", label: "chrome: screenshot")
      expect(result[:shown_label]).to eq("chrome: screenshot")

      events.clear
      result = described_class.new(labelled).run({ name: "execute", content: "ls" }, iteration: 1, call_index: 1, call_count: 1,
                                                 on_stream_event: ->(e) { events << e }, max_tool_output_chars: nil)
      expect(events.first).not_to have_key(:label)
      expect(result).not_to have_key(:shown_label)
    end

    it "carries the call's title (the process's cwd), the params unchanged" do
      run({ name: "execute", content: "cd /tmp && rspec spec/a_spec.rb" })
      expect(events.first).to include(type: :tool_call_started, title: "rspec spec/a_spec.rb",
                                      params: 'command="cd /tmp && rspec spec/a_spec.rb"')
      events.clear
      run({ name: "task_list" })
      expect(events.first).not_to have_key(:title)
    end

    it "is emitted for a denied call too, before tool_call_completed" do
      hooks.register(:before_tool_call) { |e| e[:blocked] = true }
      run
      expect(events.map { |e| e[:type] }).to eq(%i[tool_call_started tool_call_completed])
    end
  end

  describe "an ask with an approver" do
    let(:asked) { [] }
    let(:answer) { :allow }
    let(:runner) do
      approver = lambda do |verdict|
        asked << events.map { |e| e[:type] }
        answer == :allow ? verdict.settle!(:allow).tap { verdict.scope = "once" } : verdict.settle!(:deny, note: "The user declined this call.")
      end
      k = kernel
      gate = Samagotchi::Guardrails::Gate.new(-> { hooks }, approver: approver)
      k.define_singleton_method(:guardrail_gate) { gate }
      described_class.new(k)
    end

    before { hooks.register(:before_tool_call) { |e| e[:guardrail].ask!("sure?") } }

    it "asks after tool_call_started, then runs the allowed call and notes who allowed it" do
      result = run
      expect(asked).to eq([%i[tool_call_started]])
      expect(dispatched).to eq([call])
      expect(result[:activity]).to include(guardrail: { verdict: "allow", decided_by: "user", scope: "once", note: "approved (once)" })
    end

    # The UIs time a row from tool_call_started, which comes before the ask:
    # they take the wait back out.
    context "with a clock" do
      let(:now) { [100.0] }
      let(:runner) do
        approver = lambda do |verdict|
          now[0] += 2.5
          answer == :allow ? verdict.settle!(:allow).tap { verdict.scope = "once" } : verdict.settle!(:deny, note: "no")
        end
        k = kernel
        gate = Samagotchi::Guardrails::Gate.new(-> { hooks }, approver: approver)
        k.define_singleton_method(:guardrail_gate) { gate }
        described_class.new(k, clock: -> { now.first })
      end

      it "puts the approval wait on tool_call_completed" do
        run
        expect(events.last).to include(type: :tool_call_completed, waited_ms: 2500)
      end

      context "when the user declines" do
        let(:answer) { :deny }

        it "puts the wait on the blocked call's tool_call_completed too" do
          run
          expect(events.last).to include(type: :tool_call_completed, waited_ms: 2500)
        end
      end
    end

    context "when the user declines" do
      let(:answer) { :deny }

      it "does not run the call" do
        result = run
        expect(dispatched).to be_empty
        expect(result[:output]).to eq("[execute] Error: The user declined this call. It needed approval (hook): sure? Do not retry it " \
                                      "or reach the same result another way; ask the user how to proceed.")
      end
    end
  end

  describe "shown_params (the live row's params line, saved for the web's reload)" do
    let(:registry) do
      Samagotchi::Tools::Builtins.registry.tap do |r|
        r.register("save_note", schema: { parameters: { properties: {} } }, handler: ->(*) { "ok" },
                                source: "sample-plugin", preview: ->(call) { "#{call[:args]["path"]} (#{call[:args]["text"].length} chars)" })
      end
    end
    let(:runner) do
      k = kernel
      tools = registry
      k.define_singleton_method(:tools) { tools }
      described_class.new(k)
    end

    it "is the preview a plugin tool showed" do
      result = run({ name: "save_note", args: { "path" => "w.md", "text" => "hello world!" } })
      expect(result[:shown_params]).to eq("w.md (12 chars)")
      expect(events.first[:params]).to eq("w.md (12 chars)")
    end

    it "is absent for a built-in, so its saved result stays as it was" do
      expect(run).not_to have_key(:shown_params)
    end
  end

  describe "diff (what an edit/write changed, for its row)" do
    around { |ex| Dir.mktmpdir { |dir| @dir = dir; ex.run } }

    let(:kernel) do
      k = Struct.new(:hooks, :dispatched) do
        def dispatch_tool_call(call)
          dispatched << call
          out = case call[:name]
                when "edit" then Samagotchi::Tools::Edit.call(call[:content], path: call[:path])
                when "write" then Samagotchi::Tools::Write.call(call[:content], path: call[:path])
                when "sneaky" then File.write(call[:path], "changed\n") && "Error: failed after writing"
                else "ran"
                end
          { output: "[#{call[:name]}]\n#{out}", activity: { tool: call[:name], status: "ok" } }
        end
      end
      k.new(hooks, dispatched)
    end

    def path(name = "f.txt") = File.join(@dir, name)

    it "is on tool_call_completed and the run, and the model-facing output is unchanged" do
      File.write(path, "a\nb\n")
      result = run({ name: "edit", path: path, content: "<old>b</old><new>B</new>" })
      diff = { text: "@@ -1,2 +1,2 @@\n a\n-b\n+B", added: 1, removed: 1, truncated: false, new_file: false }
      expect(result[:diff]).to eq(diff)
      expect(events.last).to include(type: :tool_call_completed, diff: diff)
      expect(result[:output]).to eq("[edit]\nEdited #{path}: replaced 1 bytes with 1 bytes")
      expect(result[:capped_output]).to eq(result[:output])
    end

    it "marks a written new file" do
      expect(run({ name: "write", path: path("new.txt"), content: "x\n" })[:diff]).to include(new_file: true, added: 1)
    end

    it "is absent when the file didn't change (an edit that errors before writing)" do
      File.write(path, "a\n")
      result = run({ name: "edit", path: path, content: "<old>zzz</old><new>B</new>" })
      expect(result).not_to have_key(:diff)
      expect(events.last).not_to have_key(:diff)
    end

    it "shows a change the call made even when its result is an error" do
      File.write(path, "orig\n")
      stub_const("Samagotchi::EditPreview::TOOLS", %w[edit write sneaky])
      expect(run({ name: "sneaky", path: path })[:diff]).to include(added: 1, removed: 1)
    end

    it "refreshes a memory's index line after a write/edit that changed its file, not after one that didn't" do
      File.write(path, "a\n")
      allow(Samagotchi::MemoryBundle::IndexSync).to receive(:refresh)
      run({ name: "edit", path: path, content: "<old>zzz</old><new>B</new>" })
      expect(Samagotchi::MemoryBundle::IndexSync).not_to have_received(:refresh)
      run({ name: "edit", path: path, content: "<old>a</old><new>b</new>" })
      run({ name: "write", path: path("new.md"), content: "x\n" })
      expect(Samagotchi::MemoryBundle::IndexSync).to have_received(:refresh).with(path)
      expect(Samagotchi::MemoryBundle::IndexSync).to have_received(:refresh).with(path("new.md"))
    end

    it "is absent for a denied edit and for other tools" do
      File.write(path, "a\n")
      hooks.register(:before_tool_call) { |e| e[:blocked] = true if e[:call][:name] == "edit" }
      expect(run({ name: "edit", path: path, content: "<old>a</old><new>b</new>" })).not_to have_key(:diff)
      expect(run).not_to have_key(:diff)
    end
  end
end
