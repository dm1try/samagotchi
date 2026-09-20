# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/terminal_ui"
require "samagotchi/hooks"

RSpec.describe "TUI hooks forwarding regression" do
  # Minimal repro for the bug where TerminalUI creates a KernelLoop without
  # hooks and Engine fails to propagate its registry, leaving
  # before_generation/after_generation/before_tool_call/after_tool_call dead
  # in interactive (TUI) mode.

  around do |example|
    orig = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = orig
  end

  let(:client) { instance_double(Samagotchi::Client) }

  describe "Engine owns hooks, KernelLoop reuses them" do
    it "propagates Engine registry to an externally-supplied KernelLoop" do
      external_kernel = Samagotchi::KernelLoop.new(client: client, verbose: false)
      expect(external_kernel.hooks).to be_nil

      engine = Samagotchi::Engine.new(mode: :assist, client: client, kernel: external_kernel)

      engine_hooks = engine.instance_variable_get(:@hooks)
      expect(engine_hooks).to be_a(Samagotchi::Hooks::Registry)
      expect(external_kernel.hooks).to be(engine_hooks)
      expect(external_kernel.hooks).not_to be_nil
    end

    it "shares the same registry instance so Engine#register_hook is visible to KernelLoop" do
      external_kernel = Samagotchi::KernelLoop.new(client: client, verbose: false)
      engine = Samagotchi::Engine.new(mode: :assist, client: client, kernel: external_kernel)

      fired = []
      engine.register_hook(:before_generation) { |ev| fired << ev[:type] }

      # KernelLoop should fire the same registry entry
      external_kernel.hooks.fire(:before_generation, { type: :before_generation })
      expect(fired).to eq([:before_generation])
    end
  end

  describe "TerminalUI (TUI) integration path" do
    it "forwards the selected backend to Engine" do
      tui = Samagotchi::TerminalUI.new(mode: :assist, client: client, backend: :ruby_llm)

      expect(tui.instance_variable_get(:@engine).instance_variable_get(:@backend))
        .to be_a(Samagotchi::LLM::RubyLLMBackend)
    end

    it "TerminalUI's Engine and KernelLoop share the same hooks registry" do
      allow(client).to receive(:complete).and_return("hello")
      tui = Samagotchi::TerminalUI.new(mode: :assist, client: client)

      engine = tui.instance_variable_get(:@engine)
      kernel = tui.instance_variable_get(:@kernel)

      engine_hooks = engine.instance_variable_get(:@hooks)
      expect(engine_hooks).to be_a(Samagotchi::Hooks::Registry)
      expect(kernel.hooks).to be(engine_hooks)
    end

    it "hook registered via Engine fires during TUI's KernelLoop run (interactive REPL path)" do
      # Stub a single generation with no tool calls so KernelLoop.run completes in 1 iteration
      allow(client).to receive(:complete).and_return("hi from model")

      tui = Samagotchi::TerminalUI.new(mode: :assist, client: client)
      engine = tui.instance_variable_get(:@engine)
      kernel = tui.instance_variable_get(:@kernel)

      gen_fired = []
      tool_fired = []
      engine.register_hook(:before_generation) { |ev| gen_fired << ev[:type] }
      engine.register_hook(:before_tool_call) { |ev| tool_fired << ev[:type] }

      # TUI REPL drives KernelLoop directly, not via Engine#run_turn.
      # Before the fix kernel.hooks is nil, so no kernel-level hooks fire.
      result = kernel.run([{ role: "system", content: "sys" }, { role: "user", content: "hi" }])
      expect(result).to be_a(Samagotchi::KernelLoop::Result)
      expect(gen_fired).to include(:before_generation)

      # Also verify that mutating hooks via Engine is reflected live in Kernel
      expect(kernel.hooks).to be(engine.instance_variable_get(:@hooks))
      expect(tool_fired).to be_empty # no tools in this stub, but at least no error
    end
  end
end
