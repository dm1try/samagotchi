# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/session"
require "samagotchi/bridge"
require "samagotchi/plugin/context"
require "support/thinking_off"

# Cards (docs/plugins.md, Cards): Engine#show_card, ctx.card and the
# Bridge's CardStore (snapshot[:cards]).
RSpec.describe "Cards" do
  include_context "thinking off"

  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
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

    it "holds back what a block announces on its thread for the caller (a worker's command), not a turn's" do
      value, held = engine.holding_announcements do
        engine.show_card(source: "b", title: "held")
        engine.send(:hook_notify, "held too", :info, "plugin.rb (bundle b)")
        Thread.new { engine.show_card(source: "b", title: "other thread") }.join
        :done
      end

      expect(value).to eq(:done)
      expect(held.map { |e| e[:title] || e[:text] }).to eq(["held", "held too"])
      expect(cards.map { |c| c[:title] }).to eq(["other thread"])
      engine.show_card(source: "b", title: "after")
      expect(cards.map { |c| c[:title] }).to eq(["other thread", "after"])
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
      expect(store.list.map { |e| [e[:text], e[:in_turn]] }).to eq([["saved", false], ["in a turn", true]])
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

    it "places a card that comes during a turn but isn't the turn's (an anytime command's) after that turn" do
      turn(:turn_completed)
      turn(:turn_started)
      store.call(card("btw"))
      expect(store.list.first).to include(turns_since: 0, current: false, in_turn: false, during: true)
      store.call(card("btw", "answer"))
      turn(:turn_completed)
      expect(store.list.first).to include(title: "answer", turns_since: 0, current: false)
      expect(store.list.first).not_to have_key(:during)
      turn(:turn_started, :turn_completed)
      expect(store.list.first[:turns_since]).to eq(1)
    end

    it "keeps such a card before the next turn when its turn failed (no prompt in the history)" do
      turn(:turn_started)
      store.call(card("btw"))
      turn(:turn_failed, :turn_started, :turn_completed)
      expect(store.list.first[:turns_since]).to eq(1)
    end

    it "keeps a card replaced during a turn in its first place" do
      store.call(card("btw"))
      turn(:turn_started)
      store.call(card("btw", "answer", in_turn: true))
      expect(store.list.first).to include(title: "answer", in_turn: false, current: false, turns_since: 0)
    end

    it "keeps between-turns notices" do
      store.call({ type: :hook_notice, hook: "plugin.rb (bundle b)", text: "saved", level: :info, between_turns: true })
      expect(store.list).to eq([{ type: :hook_notice, hook: "plugin.rb (bundle b)", text: "saved", level: :info,
                                  in_turn: false, turns_since: 0, current: false }])
    end

    it "keeps a turn's notices with the step and the calls started before each" do
      store = described_class.new
      turn = ->(*types) { types.each { |type| store.call({ type: type }) } }
      notice = ->(text) { store.call({ type: :hook_notice, hook: "h", text: text, level: :warn }) }
      turn.call(:turn_started)
      notice.call("before any step")
      store.call({ type: :generation_started, iteration: 1 })
      notice.call("before call 1")
      store.call({ type: :tool_call_started, iteration: 1, call_index: 1 })
      notice.call("after call 1")
      store.call({ type: :generation_started, iteration: 2 })
      notice.call("in step 2")
      expect(store.list.last).to include(in_turn: true, current: true, iteration: 2, calls: 0)
      turn.call(:turn_canceled)

      expect(store.list.map { |e| [e[:text], e[:iteration], e[:calls], e[:in_turn], e[:turns_since], e[:current]] }).to eq(
        [["before any step", nil, 0, true, 0, false], ["before call 1", 1, 0, true, 0, false],
         ["after call 1", 1, 1, true, 0, false], ["in step 2", 2, 0, true, 0, false]]
      )
      turn.call(:turn_started, :turn_completed)
      expect(store.list.map { |e| e[:turns_since] }.uniq).to eq([1])
    end

    it "keeps the loop's asking-again rows (an empty or cut answer) in their step, as a turn's notices" do
      store = described_class.new
      store.call({ type: :turn_started })
      store.call({ type: :generation_started, iteration: 1 })
      store.call({ type: :empty_answer_retry, iteration: 1, attempt: 1, of: 2, finish_reason: "stop", thinking_chars: 9 })
      store.call({ type: :tool_call_started, iteration: 1, call_index: 1 })
      store.call({ type: :empty_answer_retry, iteration: 1, attempt: 2, of: 2, stopped_by: "loop-guard" })
      store.call({ type: :turn_completed })
      store.call({ type: :empty_answer_retry, iteration: 1, attempt: 1, of: 1 }) # no turn runs: nothing to place it in

      expect(store.list).to eq([
        { type: :empty_answer_retry, attempt: 1, of: 2, in_turn: true, iteration: 1, calls: 0, turns_since: 0, current: false },
        { type: :empty_answer_retry, attempt: 2, of: 2, stopped_by: "loop-guard", in_turn: true, iteration: 1, calls: 1,
          turns_since: 0, current: false }
      ])
    end

    it "keeps a notice that comes after its turn ended (an after_turn hook's) before the next turn" do
      turn(:turn_started, :turn_completed)
      store.call({ type: :hook_notice, hook: "h", text: "after", level: :info })
      expect(store.list.first).to include(in_turn: false, turns_since: 0, current: false)
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
