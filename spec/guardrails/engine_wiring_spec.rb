# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/memory_bundle/provenance"
require "tmpdir"
require "fileutils"

RSpec.describe "Engine guardrail wiring" do
  let(:engine) { Samagotchi::Engine.new(client: instance_double(Samagotchi::Client)) }

  # The context the Engine's gate sees now (GuardrailWiring#context).
  def guardrail_context(engine) = engine.instance_variable_get(:@guardrail_wiring).context

  it "defaults the interface to non_interactive and validates it" do
    expect(engine.interface).to eq(:non_interactive)
    engine.interface = :worker
    expect(engine.interface).to eq(:worker)
    expect { engine.interface = :nope }.to raise_error(ArgumentError)
  end

  it "gives its kernel a gate whose context names the session, the interface and the cwd" do
    engine.interface = :repl
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    engine.session = session
    gate = engine.instance_variable_get(:@kernel).guardrail_gate
    expect(gate).to be_a(Samagotchi::Guardrails::Gate)
    ctx = guardrail_context(engine)
    expect([ctx.session_id, ctx.interface, ctx.cwd]).to eq([session.id, :repl, Dir.pwd])
  end

  it "runs the Engine's hooks through the kernel's gate" do
    engine.register_hook(:before_tool_call) { |e| e[:guardrail].deny!("no") }
    gate = engine.instance_variable_get(:@kernel).guardrail_gate
    expect(gate.evaluate({ name: "execute", content: "ls" }, iteration: 1, params: "")).to be_deny
  end

  describe "#request_approval" do
    def asking(engine)
      v = Samagotchi::Guardrails::Verdict.new(call: { name: "execute", content: "git push" })
      v.ask!("pushes", rule: "git-push", source: "config", scopes: %w[once repo])
      v.context = guardrail_context(engine)
      v.targets = Samagotchi::Guardrails::Targets.for(v.call, v.context)
      v
    end

    it "denies at once in a non-interactive run" do
      v = engine.request_approval(asking(engine))
      expect(v).to be_deny
      expect(v.deny_text).to include("No one to approve it (non-interactive run).")
      expect(engine.pending_question).to be_nil
    end

    it "asks through the question flow in a worker and allows the picked scope" do
      engine.interface = :worker
      result = nil
      thread = Thread.new { result = engine.request_approval(asking(engine)) }
      wait_until(timeout: 2, interval: 0.005) { engine.pending_question }
      pending = engine.pending_question
      expect(pending).to include(kind: "approval", header: "Approve tool call?")
      expect(pending[:approval]).to include(command: "git push", rule: "git-push", scopes: %w[once repo])
      engine.answer_question(id: pending[:id], selected: [pending[:options][1]])
      thread.join(2)
      expect([result.decision, result.scope]).to eq([:allow, "repo"])
    end

    it "asks about a plugin tool by its label, as its row shows it" do
      engine.interface = :worker
      engine.instance_variable_get(:@tools).register("mcp_x_echo", schema: { name: "mcp_x_echo" }, handler: ->(*) { "" },
                                                                   label: "x: echo", source: "mcp")
      v = Samagotchi::Guardrails::Verdict.new(call: { name: "mcp_x_echo", args: { "message" => "hi" } })
      v.ask!("an MCP tool", rule: "mcp-ask", source: "config", scopes: %w[once])
      v.context = guardrail_context(engine)
      v.targets = Samagotchi::Guardrails::Targets.for(v.call, v.context)
      thread = Thread.new { engine.request_approval(v) }
      wait_until(timeout: 2, interval: 0.005) { engine.pending_question }
      pending = engine.pending_question
      expect(pending[:approval]).to include(tool: "mcp_x_echo", label: "x: echo")
      expect(pending[:question].lines.first).to start_with("x: echo: ")
      engine.cancel_question("dismissed", id: pending[:id])
      thread.join(2)
    end

    it "denies when the worker's question is dismissed" do
      engine.interface = :worker
      result = nil
      thread = Thread.new { result = engine.request_approval(asking(engine)) }
      wait_until(timeout: 2, interval: 0.005) { engine.pending_question }
      engine.cancel_question("dismissed", id: engine.pending_question[:id])
      thread.join(2)
      expect(result.deny_text).to include("The approval was cancelled.")
    end

    context "for an edit or write call" do
      around { |ex| Dir.mktmpdir { |dir| @dir = dir; ex.run } }

      def ask_for(engine, call)
        v = Samagotchi::Guardrails::Verdict.new(call: call)
        v.ask!("outside the repo", rule: "write-outside-repo", source: "config", scopes: %w[once])
        v.context = guardrail_context(engine)
        v.targets = Samagotchi::Guardrails::Targets.for(v.call, v.context)
        v
      end

      def pending_for(engine, verdict)
        thread = Thread.new { engine.request_approval(verdict) }
        wait_until(timeout: 2, interval: 0.005) { engine.pending_question }
        pending = engine.pending_question
        yield pending if block_given?
        engine.cancel_question("dismissed", id: pending[:id])
        thread.join(2)
        pending
      end

      it "shows the diff the call would make, and saves it with the pending question" do
        engine.interface = :worker
        session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: @dir)
        engine.session = session
        state_dir = File.join(@dir, "state")
        allow(engine).to receive(:session_state_dir).and_return(state_dir)
        path = File.join(@dir, "kitty.conf")
        File.write(path, "font_size 12\n")
        call = { name: "edit", path: path, old_text: "font_size 12", new_text: "font_size 14" }
        pending = pending_for(engine, ask_for(engine, call)) do
          reloaded = Samagotchi::Session.load(session.id, state_dir: state_dir).pending_question
          expect(reloaded[:approval]["preview"]).to include("text" => "@@ -1 +1 @@\n-font_size 12\n+font_size 14")
        end
        expect(pending[:approval][:preview]).to include(added: 1, removed: 1, new_file: false)
        expect(pending[:question]).to end_with("  change: +1 \u22121")
        expect(File.read(path)).to eq("font_size 12\n")
      end

      it "previews the call a before_tool_call hook replaced it with" do
        engine.interface = :worker
        path = File.join(@dir, "new.txt")
        engine.register_hook(:before_tool_call) do |e|
          e[:call] = e[:call].merge(content: "replaced\n")
          e[:guardrail].ask!("check", rule: "r", source: "config", scopes: %w[once])
        end
        gate = engine.instance_variable_get(:@kernel).guardrail_gate
        verdict = gate.evaluate({ name: "write", path: path, content: "original\n" }, iteration: 1, params: "")
        pending = pending_for(engine, verdict)
        expect(pending[:approval][:preview]).to include(text: "@@ -0,0 +1 @@\n+replaced", new_file: true)
      end

      it "asks without a preview when building it fails" do
        engine.interface = :worker
        allow(Samagotchi::EditPreview).to receive(:for).and_raise(RuntimeError, "boom")
        pending = pending_for(engine, ask_for(engine, { name: "write", path: File.join(@dir, "x"), content: "x" }))
        expect(pending[:approval]).not_to have_key(:preview)
      end

      it "gives other tools no preview" do
        engine.interface = :worker
        expect(pending_for(engine, asking(engine))[:approval]).not_to have_key(:preview)
      end
    end
  end
end

# A long-lived worker picks up edited rules: config.yml's guardrails: and
# the installed bundles' rule files are read again when one changes.
RSpec.describe "Engine guardrail rules reload" do
  around do |example|
    Dir.mktmpdir do |dir|
      saved = ENV["XDG_CONFIG_HOME"]
      ENV["XDG_CONFIG_HOME"] = dir
      @config = File.join(dir, "samagotchi", "config.yml")
      FileUtils.mkdir_p(File.dirname(@config))
      example.run
    ensure
      ENV["XDG_CONFIG_HOME"] = saved
    end
  end

  def write_config(text, bump: 0)
    File.write(@config, "default: {model: m}\n#{text}")
    time = Time.now + bump
    File.utime(time, time, @config)
  end

  def deny_rule(command) = "guardrails:\n  rules:\n    - {id: no-#{command}, tool: shell, command: 'echo #{command}', verdict: deny, reason: no}\n"

  def verdict(engine, command)
    engine.instance_variable_get(:@kernel).guardrail_gate.evaluate({ name: "execute", content: "echo #{command}" }, iteration: 1, params: "")
  end

  it "applies config.yml rules edited after the engine started, and drops a load failure once fixed" do
    write_config(deny_rule("a"))
    engine = Samagotchi::Engine.new(client: instance_double(Samagotchi::Client))
    expect(verdict(engine, "a")).to be_deny

    write_config(deny_rule("b"), bump: 5)
    expect(verdict(engine, "a")).not_to be_deny
    expect(verdict(engine, "b")).to be_deny

    write_config("guardrails:\n  rules: nope\n", bump: 10)
    expect(verdict(engine, "c")).to be_deny
    expect(engine.guardrail_failures.list.map(&:what)).to eq(["rules in config.yml"])

    write_config(deny_rule("b"), bump: 15)
    expect(verdict(engine, "c")).not_to be_deny
    expect(engine.guardrail_failures.list).to be_empty
  end
end
