# frozen_string_literal: true

require "samagotchi/hooks"

RSpec.describe Samagotchi::Hooks::Registry do
  describe "bundle hooks" do
    it "registers bundle hooks and fires them before plain hooks" do
      order = []
      subject.register_bundle("bundle-a", :before_tool_call, hook_name: "guard.rb", priority: 100) { order << :bundle }
      subject.register(:before_tool_call) { order << :plain }
      subject.fire(:before_tool_call, {})
      expect(order).to eq([:bundle, :plain])
    end

    it "orders bundle hooks by priority, then bundle, then hook_name" do
      order = []
      subject.register_bundle("b", :ev, hook_name: "z.rb", priority: 10) { order << :b10 }
      subject.register_bundle("a", :ev, hook_name: "a.rb", priority: 10) { order << :a10 }
      subject.register_bundle("a", :ev, hook_name: "b.rb", priority: 5) { order << :a5 }
      subject.fire(:ev, {})
      expect(order).to eq([:a5, :a10, :b10])
    end

    it "unregister_bundle removes only that bundle" do
      subject.register_bundle("keep", :ev, hook_name: "k.rb") { }
      subject.register_bundle("remove", :ev, hook_name: "r.rb") { }
      expect(subject.size).to eq(2)
      removed = subject.unregister_bundle("remove")
      expect(removed).to eq(1)
      expect(subject.size).to eq(1)
      subject.fire(:ev, {})
    end

    it "unregister_bundle with event restricts to one event" do
      subject.register_bundle("b", :ev1, hook_name: "h.rb") { }
      subject.register_bundle("b", :ev2, hook_name: "h.rb") { }
      subject.unregister_bundle("b", :ev1)
      expect(subject.size).to eq(1)
      subject.fire(:ev1, {})
      subject.fire(:ev2, {})
    end

    it "size covers both plain and bundle hooks" do
      subject.register(:plain) { }
      subject.register_bundle("b", :ev, hook_name: "h.rb") { }
      expect(subject.size).to eq(2)
    end

    it "clear_all clears plain hooks but SPARES bundle hooks (Policy 4)" do
      subject.register(:plain) { }
      subject.register_bundle("b", :ev, hook_name: "h.rb") { |e| e[:bundle]=true }
      subject.clear_all
      expect(subject.size).to eq(1)
      e = {}
      subject.fire(:ev, e)
      expect(e[:bundle]).to be true
      # plain should be gone
      e2 = {}
      subject.fire(:plain, e2)
      expect(e2).to be_empty
    end

    it "bundle hooks survive multiple clear_all (turn-2 regression)" do
      subject.register_bundle("b", :before_tool_call, hook_name: "g.rb", priority: 10) { |e| e[:blocked]=true }
      2.times do
        e = {}
        subject.fire(:before_tool_call, e)
        expect(e[:blocked]).to be true
        subject.clear_all
        # after clear, bundle hook should still be present for next turn
        expect(subject.size).to eq(1)
      end
    end

    it "unregister_bundle removes bundle hooks after clear_all" do
      subject.register_bundle("b", :ev, hook_name: "h.rb") { }
      subject.clear_all
      expect(subject.size).to eq(1)
      subject.unregister_bundle("b")
      expect(subject.size).to eq(0)
    end
  end
end

RSpec.describe Samagotchi::Hooks::Registry, "#fire_each" do
  it "yields the event after each hook, in firing order, and skips a raising hook" do
    registry = described_class.new
    registry.register(:e) { |ev| ev[:n] << :plain }
    registry.register(:e) { |_ev| raise "boom" }
    registry.register_bundle("b", :e, hook_name: "h") { |ev| ev[:n] << :bundle }
    seen = []
    registry.fire_each(:e, { n: [] }) { |ev| seen << ev[:n].dup }
    expect(seen).to eq([[:bundle], %i[bundle plain], %i[bundle plain]])
  end
end
