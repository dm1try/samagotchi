# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/session"
require "samagotchi/bridge"
require "samagotchi/plugin/context"

# Cards (docs/plugins.md, Cards): Engine#show_card, ctx.card and the
# Bridge's CardStore (snapshot[:cards]).
RSpec.describe "Cards" do
  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    original_thinking = ENV["THINKING_MODE"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["THINKING_MODE"] = "false"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
    ENV["THINKING_MODE"] = original_thinking
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:engine) { Samagotchi::Engine.new(mode: :assist, client: client, kernel: kernel) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:seen) { [] }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run).and_return(
      Samagotchi::KernelLoop::Result.new(output: "ok", conversation: [{ role: "model", content: "ok" }], exhausted: false,
                                         pending_tool_calls: false, tool_activity: [])
    )
    engine.subscribe(observer: ->(e) { seen << e })
  end

  def cards = seen.select { |e| e[:type] == :card }

  describe "Engine#show_card" do
    it "announces a card outside a turn, with an id, and returns the id" do
      id = engine.show_card(source: "b", title: "Hi", body: "some *text*", actions: [{ label: "Again", command: "/hello again" }])

      expect(id).to match(/\A\h{8}\z/)
      expect(cards.size).to eq(1)
      expect(cards.first).to include(type: :card, id: id, source: "b", title: "Hi", body: "some *text*", level: :info,
                                     actions: [{ label: "Again", command: "/hello again" }], in_turn: false)
    end

    it "is a turn event during a turn: the turn's sink and the observers get it" do
      engine.register_hook(:before_turn) { |_e| engine.show_card(source: "b", title: "mid", id: "c1", level: :warn) }
      sink = []
      engine.run_turn(session, "hi", on_event: ->(e) { sink << e })

      card = { type: :card, id: "c1", source: "b", title: "mid", body: "", level: :warn, actions: [], in_turn: true }
      expect(sink).to include(card)
      expect(cards.first).to include(card)
    end

    it "keeps a given id (the same id replaces a card in the UIs)" do
      2.times { |n| engine.show_card(source: "b", title: "t#{n}", id: "same") }
      expect(cards.map { |c| [c[:id], c[:title]] }).to eq([%w[same t0], %w[same t1]])
    end

    it "labels an action by its command when it has no label" do
      engine.show_card(source: "b", title: "t", actions: [{ "command" => " /x y " }])
      expect(cards.first[:actions]).to eq([{ label: "/x y", command: "/x y" }])
    end

    it "refuses a card without a title, a bad level or a bad action" do
      expect { engine.show_card(source: "b", title: " ") }.to raise_error(ArgumentError, /title/)
      expect { engine.show_card(source: "b", title: "t", level: :error) }.to raise_error(ArgumentError, /level/)
      expect { engine.show_card(source: "b", title: "t", actions: ["/x"]) }.to raise_error(ArgumentError, /Hash/)
      expect { engine.show_card(source: "b", title: "t", actions: [{ label: "x" }]) }.to raise_error(ArgumentError, /command/)
      expect { engine.show_card(source: "b", title: "t", actions: [{ command: "/a\n/b" }]) }.to raise_error(ArgumentError, /command/)
      expect { engine.show_card(source: "b", title: "t", actions: Array.new(7) { { command: "/x" } }) }
        .to raise_error(ArgumentError, /at most 6/)
      expect(cards).to be_empty
    end
  end

  describe "ctx.card" do
    it "shows the card from the plugin's bundle and returns its id" do
      ctx = Samagotchi::Plugin::Context.new(bundle: "sample", label: "plugin.rb (bundle sample)", settings: {},
                                            host: engine.send(:plugin_host))
      id = ctx.card(title: "Hello", body: "b", actions: [{ label: "Again", command: "/hello again" }])

      expect(cards.first).to include(id: id, source: "sample", title: "Hello")
      expect(ctx.card(title: "Hello 2", id: id)).to eq(id)
    end
  end

  describe "ctx.notify outside a turn" do
    it "is announced as a notice between turns, which the CardStore keeps; a turn's is a turn event" do
      ctx = Samagotchi::Plugin::Context.new(bundle: "sample", label: "plugin.rb (bundle sample)", settings: {},
                                            host: engine.send(:plugin_host))
      store = Samagotchi::Bridge::CardStore.new
      engine.subscribe(observer: store)
      ctx.notify("saved", level: :warn)
      engine.register_hook(:before_turn) { |_e| ctx.notify("in a turn") }
      engine.run_turn(session, "hi", on_event: ->(_e) {})

      notices = seen.select { |e| e[:type] == :hook_notice }
      expect(notices.map { |e| [e[:text], e[:level], e[:between_turns]] }).to eq([["saved", :warn, true], ["in a turn", :info, nil]])
      expect(notices.first[:hook]).to eq("plugin.rb (bundle sample)")
      expect(store.list.map { |e| e[:text] }).to eq(["saved"])
    end
  end

  describe Samagotchi::Bridge::CardStore do
    subject(:store) { described_class.new(capacity: 3) }

    def card(id, title = id, in_turn: false) = { type: :card, id: id, source: "b", title: title, body: "", level: :info, actions: [], in_turn: in_turn, event_seq: 1 }
    def turn(*types) = types.each { |type| store.call({ type: type }) }

    it "keeps the last cards, oldest first, without the event's seq" do
      %w[a b c d].each { |id| store.call(card(id)) }
      expect(store.list.map { |c| c[:id] }).to eq(%w[b c d])
      expect(store.list.first).to eq(type: :card, id: "b", source: "b", title: "b", body: "", level: :info, actions: [],
                                      in_turn: false, turns_since: 0, current: false)
    end

    it "replaces a card with the same id where it was, marked updated" do
      store.call(card("a"))
      store.call(card("b"))
      store.call(card("a", "a again"))
      expect(store.list.map { |c| [c[:id], c[:title], c[:updated]] }).to eq([["a", "a again", true], ["b", "b", nil]])
    end

    it "places a card by the turns completed after it (a card of a turn after that turn)" do
      store.call(card("before"))
      turn(:turn_started)
      store.call(card("during", in_turn: true))
      expect(store.list.map { |c| [c[:id], c[:turns_since], c[:current]] }).to eq([["before", 0, false], ["during", 0, true]])

      turn(:turn_completed)
      store.call(card("after"))
      turn(:turn_started, :turn_canceled, :turn_started, :turn_failed)
      expect(store.list.map { |c| [c[:id], c[:turns_since], c[:current]] })
        .to eq([["before", 2, false], ["during", 1, false], ["after", 1, false]])
    end

    it "keeps a card replaced during a turn in its first place" do
      store.call(card("btw"))
      turn(:turn_started)
      store.call(card("btw", "answer", in_turn: true))
      expect(store.list.first).to include(title: "answer", in_turn: false, current: false, turns_since: 0)
    end

    it "keeps between-turns notices, not a turn's" do
      store.call({ type: :hook_notice, hook: "plugin.rb (bundle b)", text: "saved", level: :info, between_turns: true })
      store.call({ type: :hook_notice, hook: "h", text: "in a turn", level: :info })
      expect(store.list).to eq([{ type: :hook_notice, hook: "plugin.rb (bundle b)", text: "saved", level: :info,
                                  in_turn: false, turns_since: 0, current: false }])
    end
  end

  describe "the Bridge's snapshot" do
    it "carries the cards" do
      bridge = Samagotchi::Bridge.new(engine: engine, state_dir: Dir.mktmpdir, session_id: "s1")
      engine.subscribe(observer: bridge.instance_variable_get(:@cards))
      engine.show_card(source: "b", title: "one", id: "c1")
      expect(bridge.snapshot[:cards].map { |c| c[:id] }).to eq(["c1"])
    end
  end
end
