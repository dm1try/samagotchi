# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "support/thinking_off"
require "support/test_kernel"

# Where a card (Engine#show_card), a hook's or plugin's notice
# (HookRoutes#notify) and a guardrails line (HookRoutes#guardrail_notify)
# go, by what the thread is doing: held while the plugins load, an anytime
# command's, a plugin init task's, a running turn's, or between turns
# (announced, or held for #holding_announcements' caller). Pins each route's
# payload and key order, so moving the routing (EventRoutes) changes none.
RSpec.describe Samagotchi::Engine, "event routes (characterization)" do
  include_context "thinking off"

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:engine) { described_class.new(client: test_client, kernel: test_kernel) }
  let(:extension_load) { engine.instance_variable_get(:@extension_load) }
  let(:seen) { [] }
  let(:sink) { [] }
  let(:card) { { type: :card, id: "c1", source: "b", title: "t", body: "", level: :info, actions: [] } }
  let(:card_keys) { %i[type id source title body level actions] }
  let(:notice) { { type: :hook_notice, hook: "h", text: "n", level: :info } }
  let(:notice_keys) { %i[type hook text level] }
  let(:warning) { { type: :guardrail_warning, message: "g" } }

  before { engine.subscribe(observer: ->(e) { seen << e }) }

  def loading! = allow(extension_load).to receive(:loading?).and_return(true)
  def in_turn! = allow(engine.send(:turn_state)).to receive(:in_turn_sink).and_return([true, ->(e) { sink << e }])
  def init_task! = allow(engine).to receive(:current_init_task).and_return(:an_init_task)

  def card! = engine.show_card(source: "b", title: "t", id: "c1")
  def notice! = engine.send(:hook_notify, "n", :info, "h")
  def guardrail! = engine.send(:guardrail_notify, "g")

  describe "a card (Engine#show_card)" do
    it "is held while the plugins load, marked in_turn: true, and returns its id" do
      loading!
      init_task!
      in_turn!
      engine.running_anytime { expect(card!).to eq("c1") }

      expect(extension_load.held_events.last).to eq(card.merge(in_turn: true))
      expect(extension_load.held_events.last.keys).to eq(card_keys + %i[in_turn])
      expect(seen).to be_empty
      expect(sink).to be_empty
    end

    it "on an anytime command's thread is announced at once, in_turn: false, anytime: true" do
      init_task!
      in_turn!
      _, held = engine.holding_announcements { engine.running_anytime { expect(card!).to eq("c1") } }

      expect(held).to be_empty
      expect(sink).to be_empty
      expect(seen.last).to eq(card.merge(in_turn: false, anytime: true, event_seq: 1))
      expect(seen.last.keys).to eq(card_keys + %i[in_turn anytime event_seq])
    end

    it "on a plugin's init task is announced, in_turn: false, never a turn's event nor held" do
      init_task!
      in_turn!
      _, held = engine.holding_announcements { expect(card!).to eq("c1") }

      expect(held).to be_empty
      expect(sink).to be_empty
      expect(seen.last).to eq(card.merge(in_turn: false, event_seq: 1))
      expect(seen.last.keys).to eq(card_keys + %i[in_turn event_seq])
    end

    it "during a turn is the turn's event, in_turn: true, never held" do
      in_turn!
      _, held = engine.holding_announcements { expect(card!).to eq("c1") }

      expect(held).to be_empty
      expect(sink).to eq([card.merge(in_turn: true)])
      expect(sink.last.keys).to eq(card_keys + %i[in_turn])
      expect(seen.last).to eq(card.merge(in_turn: true, event_seq: 1))
    end

    it "between turns is held for holding_announcements' caller, in_turn: false, else announced" do
      _, held = engine.holding_announcements { expect(card!).to eq("c1") }
      expect(held).to eq([card.merge(in_turn: false)])
      expect(held.last.keys).to eq(card_keys + %i[in_turn])
      expect(seen).to be_empty

      expect(card!).to eq("c1")
      expect(seen.last).to eq(card.merge(in_turn: false, event_seq: 1))
    end
  end

  describe "a notice (HookRoutes#notify)" do
    it "is held while the plugins load, unmarked" do
      loading!
      init_task!
      in_turn!
      engine.running_anytime { expect(notice!).to be_nil }

      expect(extension_load.held_events.last).to eq(notice)
      expect(extension_load.held_events.last.keys).to eq(notice_keys)
      expect(seen).to be_empty
      expect(sink).to be_empty
    end

    it "on an anytime command's thread is announced at once, between_turns: true, anytime: true" do
      init_task!
      in_turn!
      _, held = engine.holding_announcements { engine.running_anytime { expect(notice!).to be_nil } }

      expect(held).to be_empty
      expect(sink).to be_empty
      expect(seen.last).to eq(notice.merge(between_turns: true, anytime: true, event_seq: 1))
      expect(seen.last.keys).to eq(notice_keys + %i[between_turns anytime event_seq])
    end

    it "on a plugin's init task is announced, between_turns: true, never a turn's event nor held" do
      init_task!
      in_turn!
      _, held = engine.holding_announcements { expect(notice!).to be_nil }

      expect(held).to be_empty
      expect(sink).to be_empty
      expect(seen.last).to eq(notice.merge(between_turns: true, event_seq: 1))
    end

    it "during a turn is the turn's event, unmarked, never held" do
      in_turn!
      _, held = engine.holding_announcements { expect(notice!).to be_nil }

      expect(held).to be_empty
      expect(sink).to eq([notice])
      expect(seen.last).to eq(notice.merge(event_seq: 1))
    end

    it "between turns is held for holding_announcements' caller, between_turns: true, after its extra fields" do
      _, held = engine.holding_announcements do
        engine.send(:hook_notify, "n", :info, "h", fallback_for: :display, extra: { summary: "s" })
      end

      expect(held).to eq([notice.merge(fallback_for: :display, summary: "s", between_turns: true)])
      expect(held.last.keys).to eq(notice_keys + %i[fallback_for summary between_turns])
      expect(seen).to be_empty
    end
  end

  describe "a guardrails line (HookRoutes#guardrail_notify)" do
    it "is not held while the plugins load, has no anytime or init route, and is never marked" do
      loading!
      init_task!
      engine.running_anytime { expect(guardrail!).to be_nil }

      expect(extension_load.held_events).not_to include(warning)
      expect(seen.last).to eq(warning.merge(event_seq: 1))
      expect(seen.last.keys).to eq(%i[type message event_seq])
    end

    it "during a turn is the turn's event, even on an init task or an anytime thread" do
      init_task!
      in_turn!
      engine.running_anytime { expect(guardrail!).to be_nil }

      expect(sink).to eq([warning])
      expect(seen.last).to eq(warning.merge(event_seq: 1))
    end

    it "between turns is held for holding_announcements' caller, unmarked" do
      _, held = engine.holding_announcements { expect(guardrail!).to be_nil }

      expect(held).to eq([warning])
      expect(seen).to be_empty
    end
  end
end
