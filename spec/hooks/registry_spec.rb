# frozen_string_literal: true

require "samagotchi/hooks"
require "samagotchi/guardrails"

RSpec.describe Samagotchi::Hooks::Registry do
  describe "#register" do
    it "stores a hook under the given name" do
      subject.register(:test_hook) { }
      expect(subject.size).to eq(1)
    end

    it "raises for non-Symbol names" do
      expect { subject.register("not_a_symbol") { } }.to raise_error(ArgumentError, /hook name must be a Symbol/)
    end

    it "raises when no block is given" do
      expect { subject.register(:missing_block) }.to raise_error(ArgumentError, /hook block is required/)
    end

    it "overwrites an existing hook with the same name" do
      order = []
      subject.register(:dup) { order << 1 }
      subject.register(:dup) { order << 2 }
      # Now supports multiple hooks per name, so size should be 2
      expect(subject.size).to eq(2)
      subject.fire(:dup, {})
      expect(order).to eq([1, 2])
    end
  end

  describe "#fire" do
    it "calls all registered hooks with the event hash" do
      received = nil
      subject.register(:before_turn) { |event| received = event }
      event = { type: :before_turn }
      subject.fire(:before_turn, event)
      expect(received).to eq(event)
      expect(received.object_id).to eq(event.object_id) # same object by reference
    end

    it "mutates are visible (the event hash is passed by reference)" do
      subject.register(:test) { |e| e[:mutated] = true }
      event = { type: :test }
      subject.fire(:test, event)
      expect(event[:mutated]).to be true
    end

    it "skips unregistered hook names silently" do
      expect { subject.fire(:nonexistent, { type: :x }) }.not_to raise_error
    end

    it "isolates errors: a failing hook does not crash the registry" do
      subject.register(:boom) { raise StandardError, "oops" }
      expect { subject.fire(:boom, { raise: true }) }.not_to raise_error
    end

    it "only fires hooks that match the requested name" do
      values = []
      subject.register(:before_turn) { values << :before_turn }
      subject.register(:after_turn) { values << :after_turn }
      subject.fire(:before_turn, { type: :before_turn })
      expect(values).to eq([:before_turn])
    end
  end

  describe "#unregister" do
    it "removes a hook and returns true" do
      subject.register(:to_remove) { }
      expect(subject.unregister(:to_remove)).to be true
      expect(subject.size).to eq(0)
    end

    it "returns false when hook does not exist" do
      expect(subject.unregister(:ghost)).to be false
      expect(subject.size).to eq(0)
    end
  end

  describe "#clear_all" do
    it "removes all hooks" do
      subject.register(:a) { }
      subject.register(:b) { }
      subject.clear_all
      expect(subject.size).to eq(0)
    end

    it "spares persistent (config.yml) hooks" do
      calls = []
      subject.register_persistent(:a) { calls << :persistent }
      subject.register(:a) { calls << :turn }
      subject.clear_all
      subject.fire(:a, {})
      expect(calls).to eq([:persistent])
    end
  end

  describe "#register_persistent" do
    it "fires before turn-scoped hooks and can be unregistered by name" do
      calls = []
      subject.register(:a) { calls << :turn }
      subject.register_persistent(:a) { calls << :persistent }
      subject.fire(:a, {})
      expect(calls).to eq(%i[persistent turn])

      expect(subject.unregister(:a)).to be true
      expect(subject.size).to eq(0)
    end
  end
end

RSpec.describe Samagotchi::Hooks::Registry, "the hook runtime on the event" do
  it "labels each proc before it runs: bundle file, config label, turn hook" do
    labels = []
    subject.register_bundle("known-names", :before_turn, hook_name: "known_names.rb") { |e| labels << e[:hook] }
    subject.register_persistent(:before_turn, label: "audit.rb (config)") { |e| labels << e[:hook] }
    subject.register_persistent(:before_turn) { |e| labels << e[:hook] }
    subject.register(:before_turn) { |e| labels << e[:hook] }
    subject.fire(:before_turn, { type: :before_turn })
    expect(labels).to eq(["known_names.rb (bundle known-names)", "audit.rb (config)", "config hook", "turn hook"])
  end

  it "labels the procs of fire_each too" do
    labels = []
    subject.register_bundle("b", :before_tool_call, hook_name: "g.rb") { |e| labels << e[:hook] }
    subject.register(:before_tool_call) { |e| labels << e[:hook] }
    subject.fire_each(:before_tool_call, { type: :before_tool_call }) { }
    expect(labels).to eq(["g.rb (bundle b)", "turn hook"])
  end

  it "gives every hook notify, ask_user and stop_turn, and keeps the fire site's keys" do
    seen = nil
    subject.register(:before_turn) { |e| seen = e }
    event = { type: :before_turn, messages: [] }
    subject.fire(:before_turn, event)
    expect(seen.object_id).to eq(event.object_id)
    expect(event).to include(type: :before_turn, messages: [])
    expect(%i[notify ask_user stop_turn].map { |k| event[k] }).to all(respond_to(:call))
  end

  it "does not add the runtime to an event nobody listens to" do
    event = { type: :nothing }
    subject.fire(:nothing, event)
    expect(event).to eq({ type: :nothing })
  end

  it "makes the helpers no-ops without a runtime: notify nil, ask_user nil, stop_turn false" do
    results = {}
    subject.register(:before_turn) do |e|
      results[:notify] = e[:notify].call("hi")
      results[:ask] = e[:ask_user].call(question: "q", options: %w[a b])
      results[:stop] = e[:stop_turn].call("why")
    end
    subject.fire(:before_turn, { type: :before_turn })
    expect(results).to eq(notify: nil, ask: nil, stop: false)
  end

  describe "with a runtime" do
    let(:calls) { [] }
    let(:runtime) do
      Samagotchi::Hooks::Runtime.new(
        notify: ->(**kw) { calls << [:notify, kw] },
        ask_user: ->(**kw) { calls << [:ask, kw]; { selected: ["a"], freeform: nil } },
        stop_turn: ->(**kw) { calls << [:stop, kw]; true }
      )
    end

    before { subject.runtime = runtime }

    it "routes notify with the text, level and the calling hook's label" do
      subject.register_bundle("kn", :after_turn, hook_name: "k.rb") { |e| e[:notify].call("looks off", level: :warn) }
      subject.register(:after_turn) { |e| e[:notify].call("fine") }
      subject.fire(:after_turn, { type: :after_turn })
      expect(calls).to eq([[:notify, { text: "looks off", level: :warn, hook: "k.rb (bundle kn)" }],
                           [:notify, { text: "fine", level: :info, hook: "turn hook" }]])
    end

    it "routes ask_user with defaults filled in and returns the runtime's answer" do
      answer = nil
      subject.register(:before_turn) { |e| answer = e[:ask_user].call(question: "which?", options: %w[a b]) }
      subject.fire(:before_turn, { type: :before_turn })
      expect(calls).to eq([[:ask, { question: "which?", options: %w[a b], header: nil, allow_freeform: false, hook: "turn hook" }]])
      expect(answer).to eq(selected: ["a"], freeform: nil)
    end

    it "stop_turn cancels through the runtime and returns true" do
      stopped = nil
      subject.register(:before_generation) { |e| stopped = e[:stop_turn].call("enough") }
      subject.fire(:before_generation, { type: :before_generation, iteration: 1 })
      expect(calls).to eq([[:stop, { reason: "enough", hook: "turn hook" }]])
      expect(stopped).to be(true)
    end

    it "stop_turn from before_tool_call also denies the call" do
      verdict = Samagotchi::Guardrails::Verdict.new(call: { name: "execute", content: "ls" })
      subject.register_bundle("kn", :before_tool_call, hook_name: "k.rb") { |e| e[:stop_turn].call("bad call") }
      subject.fire_each(:before_tool_call, { type: :before_tool_call, guardrail: verdict }) { }
      expect(verdict).to be_deny
      expect(verdict.reason).to eq("the turn was stopped by k.rb (bundle kn): bad call")
      expect(calls.map(&:first)).to eq([:stop])
    end

    it "stop_turn after the turn does nothing and returns false" do
      results = []
      subject.register(:after_turn) { |e| results << e[:stop_turn].call("late") }
      subject.register(:session_end) { |e| results << e[:stop_turn].call("late") }
      subject.fire(:after_turn, { type: :after_turn })
      subject.fire(:session_end, { type: :session_end })
      expect(results).to eq([false, false])
      expect(calls).to be_empty
    end
  end
end

RSpec.describe Samagotchi::Hooks do
  describe "module" do
    it "exposes REGISTRY_CLASS" do
      expect(Samagotchi::Hooks.const_defined?(:REGISTRY_CLASS)).to be true
      expect(Samagotchi::Hooks::REGISTRY_CLASS).to eq(Samagotchi::Hooks::Registry)
    end
  end
end
