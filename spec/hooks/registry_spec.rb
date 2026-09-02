# frozen_string_literal: true

require "samagotchi/hooks"

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
