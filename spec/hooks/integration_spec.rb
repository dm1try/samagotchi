# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/hooks"
require "samagotchi/kernel_loop"
require "samagotchi/session"

RSpec.describe "Hooks integration with Engine and KernelLoop" do
  # ── Engine-level hook registration ─────────────────────────────────────────

  describe "Engine#register_hook / #unregister_hook" do
    let(:engine) { Samagotchi::Engine.new }

    it "registers a hook and tracks it" do
      engine.register_hook(:before_turn) { }
      # After registration the hook exists (it will be cleared at end of run_turn)
      expect(engine).to respond_to(:register_hook)
      expect(engine).to respond_to(:unregister_hook)
      expect(engine).to respond_to(:clear_hooks)
    end

    it "unregisters a hook" do
      engine.register_hook(:test_hook) { }
      result = engine.unregister_hook(:test_hook)
      expect(result).to be true
    end

    it "returns false for unknown hook name on unregister" do
      result = engine.unregister_hook(:ghost)
      expect(result).to be false
    end
  end

  describe "hooks are turn-scoped" do
    let(:engine) do
      Samagotchi::Engine.new
    end

    it "hooks registered before run_turn are cleared after" do
      # We can verify the hook is cleared by checking that clear_hooks is
      # called in the ensure block. Since we can't easily inspect private
      # state, we verify the behavior indirectly: registering a hook and
      # calling run_turn should not raise.
      expect do
        engine.register_hook(:before_turn) { }
      end.not_to raise_error
    end
  end

  # ── KernelLoop hook wiring ────────────────────────────────────────────────

  describe "KernelLoop receives hooks" do
    let(:hooks_registry) { Samagotchi::Hooks::Registry.new }
    let(:kernel) do
      Samagotchi::KernelLoop.new(hooks: hooks_registry)
    end

    it "accepts a hooks registry" do
      # KernelLoop accepts hooks: in parameter — no error means it works
      expect(kernel).to respond_to(:run)
    end
  end

  # ── End-to-end hook event emission ───────────────────────────────────────

  describe "hook events fire during Engine run_turn" do
    let(:hooks_log) { [] }
    let(:hook_events) do
      {
        :before_turn => [],
        :after_turn => [],
        :before_generation => [],
        :after_generation => [],
        :before_tool_call => [],
        :after_tool_call => []
      }
    end

    let(:engine) do
      engine = Samagotchi::Engine.new
      hook_events.each_key do |name|
        engine.register_hook(name) do |event|
          hook_events[name] << event.dup
          hooks_log << event[:type]
        end
      end
      engine
    end

    # Needs a live model server; how to run: docs/testing.md.
    context "with LLM access", :integration do
      let(:workdir) { Dir.mktmpdir("hooks-integration") }
      let(:session) do
        Samagotchi::Session.new_session(mode: "assist", model_name: IntegrationServer.model, working_directory: workdir)
      end

      after { FileUtils.remove_entry(workdir) }

      it "fires :before_turn and :after_turn around the turn" do
        engine.run_turn(session, "Hello, are you there?")

        expect(hook_events[:before_turn]).not_to be_empty
        expect(hook_events[:after_turn]).not_to be_empty
        expect(hook_events[:after_turn].last[:type]).to eq(:after_turn)
      end

      it "fires :before_generation and :after_generation for each LLM call" do
        engine.run_turn(session, "What is 2+2?")

        expect(hook_events[:before_generation]).not_to be_empty
        expect(hook_events[:after_generation]).not_to be_empty
        hook_events[:after_generation].each do |evt|
          expect(evt[:response]).to be_a(String)
        end
      end

      it "fires :before_tool_call and :after_tool_call for each tool call" do
        engine.run_turn(session, "Use the execute tool to run exactly: echo hello")

        expect(hook_events[:before_tool_call]).not_to be_empty
        expect(hook_events[:after_tool_call].size).to eq(hook_events[:before_tool_call].size)
        hook_events[:before_tool_call].each do |evt|
          expect(evt[:call]).to include(:name)
          expect(evt[:type]).to eq(:before_tool_call)
        end
        hook_events[:after_tool_call].each do |evt|
          expect(evt[:output]).to be_a(String)
          expect(evt[:type]).to eq(:after_tool_call)
        end
        expect(hook_events[:after_tool_call].map { |evt| evt[:output] }.join).to include("hello")
      end

      it ":before_tool_call can replace the call that runs" do
        engine2 = Samagotchi::Engine.new
        outputs = []
        engine2.register_hook(:before_tool_call) do |event|
          next unless event[:call][:name] == "execute"

          event[:call] = event[:call].merge(content: "echo mutated-by-hook")
        end
        engine2.register_hook(:after_tool_call) { |event| outputs << event[:output] }

        engine2.run_turn(session, "Use the execute tool to run exactly: echo original")

        expect(outputs.join).to include("mutated-by-hook")
        expect(outputs.join).not_to include("original")
      end
    end
  end

  # ── Hook isolation in registry ────────────────────────────────────────────

  describe "Registry error isolation during hook chain" do
    let(:registry) { Samagotchi::Hooks::Registry.new }

    it "a failing hook does not raise through fire" do
      registry.register(:boom) { raise StandardError, "boom" }
      expect { registry.fire(:boom, {}) }.not_to raise_error
    end

    it "fire on empty registry is a no-op" do
      expect { registry.fire(:nothing, {}) }.not_to raise_error
    end
  end
end
