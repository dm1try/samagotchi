# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/kernel_loop"
require "samagotchi/session"
require "samagotchi/bridge"
require "samagotchi/turn_flow"
require "samagotchi/plugin/context"
require "support/thinking_off"
require "support/test_kernel"

# Cards (docs/plugins.md, Cards): Engine#show_card, ctx.card and the
# Bridge's CardStore (snapshot[:cards]).
RSpec.describe "Cards" do
  include_context "thinking off"

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { Samagotchi::Engine.new(client: client, kernel: kernel) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:seen) { [] }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run).and_return(
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: [{ role: "model", content: "ok" }], exhausted: false,
                                       pending_tool_calls: false, tool_activity: [])
    )
    engine.subscribe(observer: ->(e) { seen << e })
  end

  def cards = seen.select { |e| e[:type] == :card }

  # A store's events as a real turn sends them: an id at :turn_started, and by
  # a kept turn's end event its opening in the conversation the listing reads.
  def conversation = (@conversation ||= [])
  def listed(of = store) = of.list(messages: conversation)
  def opened(id) = conversation << { role: "user", content: "p", turn_id: id }
  def rollback = conversation.pop

  # @param opener [Boolean] false: the turn leaves no opening (a reminder, a
  #   Continue, a prompt stopped before the model)
  def turn(*types, on: store, opener: true, **started)
    types.each do |type|
      case type
      when :turn_started
        @turn_no = @turn_no.to_i + 1
        @running_id = "t#{@turn_no}"
        on.call({ type: type, turn_id: @running_id, **started })
      when :turn_completed, :turn_canceled
        turn(:turn_started, on: on, **started) unless @running_id
        opened(@running_id) if opener
        @running_id = nil
        on.call({ type: type })
      when :turn_failed
        turn(:turn_started, on: on, **started) unless @running_id
        @running_id = nil
        on.call({ type: type })
      end
    end
  end

  def failed_keeping_steps(on: store)
    opened(@running_id)
    @running_id = nil
    on.call({ type: :turn_failed, kept_steps: 5 })
  end

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

    it "carries fallback_for between turns and in a turn, and the CardStore keeps it" do
      ctx = Samagotchi::Plugin::Context.new(bundle: "sample", label: "plugin.rb (bundle sample)", settings: {},
                                            host: engine.send(:plugin_host))
      store = Samagotchi::Bridge::CardStore.new
      engine.subscribe(observer: store)
      ctx.notify("between", fallback_for: :display)
      engine.register_hook(:before_turn) { |_e| ctx.notify("in a turn", fallback_for: "display") }
      engine.run_turn(session, "hi", on_event: ->(_e) {})
      ctx.notify("plain")

      notices = seen.select { |e| e[:type] == :hook_notice }
      expect(notices.map { |e| [e[:text], e[:fallback_for]] }).to eq([["between", :display], ["in a turn", :display], ["plain", nil]])
      listing = store.list
      expect(listing.map { |e| [e[:text], e[:in_turn], e[:fallback_for]] })
        .to eq([["between", false, :display], ["in a turn", true, :display], ["plain", false, nil]])
      expect(listing.last).not_to have_key(:fallback_for)
    end

    it "keeps fallback_for on a notice held while the plugins load" do
      extension_load = engine.instance_variable_get(:@extension_load)
      allow(extension_load).to receive(:loading?).and_return(true)
      engine.send(:hook_notify, "held", :info, "plugin.rb (bundle b)", fallback_for: :display)

      expect(extension_load.held_events.last).to include(text: "held", fallback_for: :display)
    end

    it "still takes PluginTasks' positional notify (text, level, source)" do
      engine.instance_variable_get(:@plugin_tasks).instance_variable_get(:@notify).call("left out", :warn, "b")
      notice = seen.find { |e| e[:type] == :hook_notice }
      expect(notice).to include(hook: "b", text: "left out", level: :warn, between_turns: true)
      expect(notice).not_to have_key(:fallback_for)
    end
  end

  describe Samagotchi::Bridge::CardStore do
    subject(:store) { described_class.new(capacity: 3, messages: -> { conversation }) }

    def card(id, title = id, in_turn: false) = { type: :card, id: id, source: "b", title: title, body: "", level: :info, actions: [], in_turn: in_turn, event_seq: 1 }

    it "keeps the last cards, oldest first, without the event's seq" do
      %w[a b c d].each { |id| store.call(card(id)) }
      expect(listed.map { |c| c[:id] }).to eq(%w[b c d])
      expect(listed.first).to eq(type: :card, id: "b", source: "b", title: "b", body: "", level: :info, actions: [],
                                 in_turn: false, turns_since: 0, current: false)
    end

    it "caps notices apart from cards and questions, so a burst of notices evicts only older notices" do
      store.call(card("a"))
      turn(:turn_started)
      store.call({ type: :question_requested, pending_question: { id: "q1", question: "Allow?", kind: "approval" } })
      %w[n1 n2 n3 n4 n5].each { |text| store.call({ type: :hook_notice, hook: "h", text: text, level: :info }) }
      store.call({ type: :empty_answer_retry, attempt: 1, of: 2 })
      expect(listed.map { |e| e[:id] || e[:text] || e.dig(:pending_question, :id) || e[:type] })
        .to eq(["a", "q1", "n4", "n5", :empty_answer_retry])
    end

    it "never evicts an open question: the oldest other card or answered question goes" do
      turn(:turn_started)
      store.call({ type: :question_requested, pending_question: { id: "q1", question: "Which?" } })
      store.call({ type: :question_requested, pending_question: { id: "q2", question: "Which?" } })
      store.call({ type: :question_answered, id: "q2", answer: { selected: ["A"] } })
      %w[a b c].each { |id| store.call(card(id, in_turn: true)) }
      expect(listed.map { |e| e[:id] || e.dig(:pending_question, :id) }).to eq(%w[q1 b c])
      store.call({ type: :question_requested, pending_question: { id: "q3", question: "Which?" } })
      store.call({ type: :question_requested, pending_question: { id: "q4", question: "Which?" } })
      store.call({ type: :question_requested, pending_question: { id: "q5", question: "Which?" } })
      expect(listed.map { |e| e[:id] || e.dig(:pending_question, :id) }).to eq(%w[q1 q3 q4 q5])
    end

    it "replaces a card with the same id where it was, marked updated" do
      store.call(card("a"))
      store.call(card("b"))
      store.call(card("a", "a again"))
      expect(listed.map { |c| [c[:id], c[:title], c[:updated]] }).to eq([["a", "a again", true], ["b", "b", nil]])
    end

    it "places a card by the turns completed after it (a card of a turn after that turn)" do
      store.call(card("before"))
      turn(:turn_started)
      store.call(card("during", in_turn: true))
      expect(listed.map { |c| [c[:id], c[:turns_since], c[:current]] }).to eq([["before", 0, false], ["during", 0, true]])

      turn(:turn_completed)
      store.call(card("after"))
      turn(:turn_started, :turn_canceled, :turn_started, :turn_failed)
      expect(listed.map { |c| [c[:id], c[:turns_since], c[:current]] })
        .to eq([["before", 2, false], ["during", 1, false], ["after", 1, false]])
    end

    it "places a card that comes during a turn but isn't the turn's (an anytime command's) after that turn" do
      turn(:turn_completed)
      turn(:turn_started)
      store.call(card("btw"))
      expect(listed.first).to include(turns_since: 0, current: false, in_turn: false, during: true)
      store.call(card("btw", "answer"))
      turn(:turn_completed)
      expect(listed.first).to include(title: "answer", turns_since: 0, current: false)
      expect(listed.first).not_to have_key(:during)
      turn(:turn_started, :turn_completed)
      expect(listed.first[:turns_since]).to eq(1)
    end

    it "keeps such a card before the next turn when its turn failed (no prompt in the history)" do
      turn(:turn_started)
      store.call(card("btw"))
      turn(:turn_failed, :turn_started, :turn_completed)
      expect(listed.first[:turns_since]).to eq(1)
    end

    it "counts a failed turn whose work stayed (kept_steps) as a kept turn: its card stays with it" do
      turn(:turn_completed)
      turn(:turn_started)
      store.call(card("during", in_turn: true))
      failed_keeping_steps
      expect(listed.first).to include(turns_since: 0, current: false)
      turn(:turn_started, :turn_completed)
      expect(listed.first).to include(turns_since: 1, current: false)
    end

    describe "a turn taken back (!rollback: its opening leaves the messages)" do
      it "takes its count back: a card before it is at the end again, and above the next turn" do
        turn(:turn_started, :turn_completed)
        store.call(card("before"))
        turn(:turn_started, :turn_canceled)
        expect(listed.first[:turns_since]).to eq(1)
        rollback
        expect(listed.first[:turns_since]).to eq(0)
        turn(:turn_started, :turn_completed)
        expect(listed.first[:turns_since]).to eq(1)
      end

      it "does the same for a failed turn whose work stayed" do
        store.call(card("before"))
        turn(:turn_started)
        failed_keeping_steps
        rollback
        turn(:turn_started, :turn_completed)
        expect(listed.first[:turns_since]).to eq(1)
      end

      it "keeps a card shown after the turn before the next one" do
        turn(:turn_started, :turn_canceled)
        store.call(card("after"))
        rollback
        expect(listed.first[:turns_since]).to eq(0)
        turn(:turn_started, :turn_completed)
        expect(listed.first[:turns_since]).to eq(1)
      end

      it "keeps the turn's own card where the turn was, as a card between turns, with no actions" do
        turn(:turn_started, :turn_completed)
        turn(:turn_started)
        store.call(card("own", in_turn: true).merge(actions: [{ label: "Nudge", command: "/checkin nudge" }]))
        turn(:turn_canceled)
        rollback
        expect(listed.first).to include(id: "own", in_turn: false, actions: [], turns_since: 0, current: false)
        turn(:turn_started)
        expect(listed.first).to include(in_turn: false, current: false)
        turn(:turn_completed)
        expect(listed.first[:turns_since]).to eq(1)
      end

      it "leaves an earlier turn's own card in that turn" do
        turn(:turn_started)
        store.call(card("first", in_turn: true))
        turn(:turn_completed, :turn_started, :turn_canceled)
        rollback
        expect(listed.first).to include(id: "first", in_turn: true, turns_since: 0, current: false)
      end

      it "takes the turn's rows with it (no step to sit in); its hook notice stays between turns" do
        wide = described_class.new
        turn(:turn_started, on: wide)
        wide.call({ type: :generation_started, iteration: 2 })
        wide.call({ type: :hook_notice, hook: "h", text: "why", level: :warn })
        wide.call({ type: :empty_answer_retry, attempt: 1, of: 2 })
        wide.call({ type: :steer_cut, source: "x" })
        wide.call({ type: :llm_context_edited, moment: "m" })
        wide.call({ type: :question_requested, pending_question: { id: "q1", question: "Which?" } })
        wide.call({ type: :question_answered, id: "q1", answer: { selected: ["A"] } })
        turn(:turn_canceled, on: wide)
        rollback
        expect(listed(wide)).to eq([{ type: :hook_notice, hook: "h", text: "why", level: :warn, in_turn: false, turns_since: 0, current: false }])
      end

      it "stops at no turns: nothing goes negative, and the next turn counts" do
        store.call(card("before"))
        2.times { rollback }
        expect(listed.first[:turns_since]).to eq(0)
        turn(:turn_started, :turn_completed)
        expect(listed.first[:turns_since]).to eq(1)
      end
    end

    it "keeps a failed turn's own card before the next turn, not as that turn's (nothing of it stayed)" do
      turn(:turn_started, :turn_completed, :turn_started)
      store.call(card("own", in_turn: true))
      turn(:turn_failed)
      expect(listed.first).to include(in_turn: false, turns_since: 0, current: false)
      turn(:turn_started)
      expect(listed.first).to include(current: false)
      turn(:turn_completed)
      expect(listed.first[:turns_since]).to eq(1)
    end

    it "keeps a card replaced during a turn in its first place" do
      store.call(card("btw"))
      turn(:turn_started)
      store.call(card("btw", "answer", in_turn: true))
      expect(listed.first).to include(title: "answer", in_turn: false, current: false, turns_since: 0)
    end

    it "keeps the load warnings (guardrails, plugins) before the turns that came after them" do
      store.call({ type: :guardrail_warning, message: "rules in config.yml failed to load (x)" })
      store.call({ type: :guardrail_warning, message: "plugin p.rb (bundle c) failed to load (y)", label: "plugins" })
      turn(:turn_started, :turn_completed)
      expect(listed).to eq([
        { type: :guardrail_warning, message: "rules in config.yml failed to load (x)", in_turn: false, turns_since: 1, current: false },
        { type: :guardrail_warning, message: "plugin p.rb (bundle c) failed to load (y)", label: "plugins", in_turn: false,
          turns_since: 1, current: false }
      ])
    end

    it "keeps between-turns notices" do
      store.call({ type: :hook_notice, hook: "plugin.rb (bundle b)", text: "saved", level: :info, between_turns: true })
      expect(listed).to eq([{ type: :hook_notice, hook: "plugin.rb (bundle b)", text: "saved", level: :info,
                              in_turn: false, turns_since: 0, current: false }])
    end

    it "keeps a turn's notices with the step and the calls started before each" do
      store = described_class.new
      notice = ->(text) { store.call({ type: :hook_notice, hook: "h", text: text, level: :warn }) }
      turn(:turn_started, on: store)
      notice.call("before any step")
      store.call({ type: :generation_started, iteration: 1 })
      notice.call("before call 1")
      store.call({ type: :tool_call_started, iteration: 1, call_index: 1 })
      notice.call("after call 1")
      store.call({ type: :generation_started, iteration: 2 })
      notice.call("in step 2")
      expect(listed(store).last).to include(in_turn: true, current: true, iteration: 2, calls: 0)
      turn(:turn_canceled, on: store)

      expect(listed(store).map { |e| [e[:text], e[:iteration], e[:calls], e[:in_turn], e[:turns_since], e[:current]] }).to eq(
        [["before any step", nil, 0, true, 0, false], ["before call 1", 1, 0, true, 0, false],
         ["after call 1", 1, 1, true, 0, false], ["in step 2", 2, 0, true, 0, false]]
      )
      turn(:turn_started, :turn_completed, on: store)
      expect(listed(store).map { |e| e[:turns_since] }.uniq).to eq([1])
    end

    it "keeps the loop's asking-again rows (an empty or cut answer) in their step, as a turn's notices" do
      store = described_class.new
      turn(:turn_started, on: store)
      store.call({ type: :generation_started, iteration: 1 })
      store.call({ type: :empty_answer_retry, iteration: 1, attempt: 1, of: 2, finish_reason: "stop", thinking_chars: 9 })
      store.call({ type: :tool_call_started, iteration: 1, call_index: 1 })
      store.call({ type: :empty_answer_retry, iteration: 1, attempt: 2, of: 2, stopped_by: "loop-guard" })
      turn(:turn_completed, on: store)
      store.call({ type: :empty_answer_retry, iteration: 1, attempt: 1, of: 1 }) # no turn runs: nothing to place it in

      expect(listed(store)).to eq([
        { type: :empty_answer_retry, attempt: 1, of: 2, in_turn: true, iteration: 1, calls: 0, turns_since: 0, current: false },
        { type: :empty_answer_retry, attempt: 2, of: 2, stopped_by: "loop-guard", in_turn: true, iteration: 1, calls: 1,
          turns_since: 0, current: false }
      ])
    end

    it "keeps a steer's cut row in its step, and evicts it as a notice, not a card" do
      store = described_class.new(capacity: 2)
      store.call(card("a"))
      turn(:turn_started, on: store)
      store.call({ type: :generation_started, iteration: 1 })
      store.call({ type: :steer_cut, iteration: 1, source: "chi_send" })
      expect(listed(store).last).to eq({ type: :steer_cut, source: "chi_send", in_turn: true, iteration: 1, calls: 0,
                                         turns_since: 0, current: true })
      store.call({ type: :hook_notice, hook: "h", text: "n1", level: :info })
      store.call({ type: :hook_notice, hook: "h", text: "n2", level: :info })
      expect(listed(store).map { |e| e[:id] || e[:text] || e[:type] }).to eq(%w[a n1 n2])
    end

    it "keeps a ✂ row in its step, saved, and caps ✂ rows apart from notices and cards" do
      dir = Dir.mktmpdir("chi-cards")
      path = File.join(dir, "cards.json")
      store = described_class.new(capacity: 2, path: path)
      row = lambda { |n|
        { type: :llm_context_edited, moment: "request", why: "next_request", freed_tokens: n, tail_tokens: 9,
          staged: 0, text: "✂ stubbed 1 stale read · frees ~#{n} tokens",
          groups: [{ kind: "stale", items: [{ id: "t1", tool: "read", title: "a.rb", note: "a.rb: superseded" }] }] }
      }
      store.call(card("a"))
      store.call({ type: :hook_notice, hook: "h", text: "n1", level: :info, between_turns: true })
      turn(:turn_started, on: store)
      store.call({ type: :generation_started, iteration: 2 })
      store.call({ type: :tool_call_started, iteration: 2, call_index: 1 })
      store.call(row.call(1))
      expect(listed(store).last).to eq(row.call(1).merge(in_turn: true, iteration: 2, calls: 1, turns_since: 0, current: true))
      store.call(row.call(2))
      store.call(row.call(3))
      expect(listed(store).map { |e| e[:id] || e[:text] }).to eq(["a", "n1", row.call(2)[:text], row.call(3)[:text]])

      turn(:turn_completed, on: store)
      later = described_class.saved(dir, messages: conversation)
      expect(later.last).to include(type: :llm_context_edited, groups: row.call(3)[:groups], in_turn: true, iteration: 2)
    ensure
      FileUtils.remove_entry(dir)
    end

    it "keeps a turn's questions with how each was answered or cancelled, in their step" do
      store = described_class.new
      q1 = { id: "q1", question: "Which?", options: %w[A B], status: "pending" }
      q2 = { id: "q2", question: "Allow?", kind: "approval", status: "pending" }
      turn(:turn_started, on: store)
      store.call({ type: :generation_started, iteration: 1 })
      store.call({ type: :question_requested, pending_question: q1 })
      expect(listed(store).last).to include(type: :question, current: true)
      expect(listed(store).last).not_to include(:answer)
      store.call({ type: :question_answered, id: "q1", answer: { selected: ["A"] } })
      store.call({ type: :tool_call_started, iteration: 1, call_index: 1 })
      store.call({ type: :question_requested, pending_question: q2 })
      store.call({ type: :question_cancelled, id: "q2", reason: "turn ended" })
      turn(:turn_completed, on: store)

      expect(listed(store)).to eq([
        { type: :question, pending_question: q1, answer: { selected: ["A"] }, in_turn: true, iteration: 1, calls: 0,
          turns_since: 0, current: false },
        { type: :question, pending_question: q2, cancelled: true, reason: "turn ended", in_turn: true, iteration: 1, calls: 1,
          turns_since: 0, current: false }
      ])
    end

    it "keeps a notice that comes after its turn ended (an after_turn hook's) before the next turn" do
      turn(:turn_started, :turn_completed)
      store.call({ type: :hook_notice, hook: "h", text: "after", level: :info })
      expect(listed.first).to include(in_turn: false, turns_since: 0, current: false)
    end

    describe "the turns that leave no opening" do
      def before_it = store.call(card("before"))

      it "a reminder's turn counts nothing, over 3 firings; a card shown after one sits with the same turn" do
        turn(:turn_started, :turn_completed)
        before_it
        3.times { turn(:turn_started, :turn_completed, opener: false, continue: true) }
        expect(listed.first[:turns_since]).to eq(0)
        store.call(card("after"))
        turn(:turn_started, :turn_completed)
        expect(listed.map { |c| c[:turns_since] }).to eq([1, 1])
      end

      it "a Continue counts nothing, nor does its !rollback; its rows stay in-turn" do
        turn(:turn_started, :turn_completed)
        before_it
        turn(:turn_started, continue: true)
        store.call({ type: :hook_notice, hook: "h", text: "row", level: :info })
        expect(listed.last).to include(in_turn: true, current: true)
        turn(:turn_completed, opener: false)
        expect(listed.map { |c| [c[:id] || c[:text], c[:turns_since], c[:in_turn]] }).to eq([["before", 0, false], ["row", 0, true]])
        # Its !rollback: the conversation goes back to where it was, the same.
        expect(listed.first[:turns_since]).to eq(0)
        turn(:turn_started, :turn_completed)
        expect(listed.first[:turns_since]).to eq(1)
      end

      it "a failed Continue's rows don't stay: it left nothing either" do
        turn(:turn_started, :turn_completed)
        turn(:turn_started, continue: true)
        store.call({ type: :hook_notice, hook: "h", text: "why", level: :warn })
        store.call({ type: :empty_answer_retry, attempt: 1, of: 1 })
        turn(:turn_failed)
        expect(listed).to contain_exactly(include(type: :hook_notice, in_turn: false, turns_since: 0))
      end

      it "a Stop before the model counts nothing, and its card no longer reads as the next turn's" do
        turn(:turn_started, :turn_completed)
        before_it
        turn(:turn_started)
        store.call(card("own", in_turn: true).merge(actions: [{ label: "Nudge", command: "/x" }]))
        turn(:turn_canceled, opener: false)
        expect(listed.map { |c| [c[:id], c[:turns_since], c[:in_turn]] }).to eq([["before", 0, false], ["own", 0, false]])
        expect(listed.last[:actions]).to eq([])
        turn(:turn_started, :turn_completed)
        expect(listed.map { |c| [c[:id], c[:turns_since], c[:in_turn]] }).to eq([["before", 1, false], ["own", 1, false]])
      end

      it "a wake stopped before the model, its note unmarked, counts nothing" do
        turn(:turn_started, :turn_completed)
        before_it
        # The wake's note opens the turn, and goes back to a plain note after.
        wake = { role: "system", kind: "note", content: "done", turn_start: true, turn_id: "w1" }
        conversation << wake
        store.call({ type: :turn_started, turn_id: "w1", continue: true })
        expect(listed.first[:turns_since]).to eq(1)
        store.call({ type: :turn_canceled })
        conversation[-1] = wake.except(:turn_start, :turn_id)
        expect(listed.first[:turns_since]).to eq(0)
      end
    end

    describe "an opening with no id, and an entry after it" do
      def reason = conversation << { role: "user", content: "too slow" }

      it "a card shown after /continue no's reason stays below it" do
        turn(:turn_started, :turn_completed)
        turn(:turn_started, continue: true)
        turn(:turn_completed, opener: false)
        reason
        store.call(card("c"))
        expect(listed.first[:turns_since]).to eq(0)
        turn(:turn_started, :turn_completed)
        expect(listed.first[:turns_since]).to eq(1)
      end

      it "a card shown before the reason stays above it" do
        turn(:turn_started, :turn_completed)
        turn(:turn_started, continue: true)
        turn(:turn_completed, opener: false)
        store.call(card("c"))
        reason
        expect(listed.first[:turns_since]).to eq(1)
        turn(:turn_started, :turn_completed)
        expect(listed.first[:turns_since]).to eq(2)
      end

      it "a card after a turn holding a recovery line stays after that turn, and one from during it too" do
        turn(:turn_started)
        store.call(card("during"))
        store.call({ type: :hook_notice, hook: "h", text: "anytime", level: :info, between_turns: true })
        recovery = { role: "user", content: "Continue, the tool call was cut." }
        opened(@running_id)
        conversation << recovery
        @running_id = nil
        store.call({ type: :turn_completed })
        store.call(card("after"))
        expect(listed.map { |c| c[:turns_since] }).to eq([0, 0, 0])
        turn(:turn_started, :turn_completed)
        expect(listed.map { |c| c[:turns_since] }).to eq([1, 1, 1])
      end

      it "a turn's own row counts it, as it comes after the row's step on the page" do
        turn(:turn_started, :turn_completed)
        turn(:turn_started, continue: true)
        store.call(card("own", in_turn: true))
        turn(:turn_completed, opener: false)
        reason
        expect(listed.first).to include(in_turn: true, turns_since: 1)
      end

      it "holds no count past a rollback that took the reason away" do
        turn(:turn_started, :turn_completed)
        turn(:turn_started, continue: true)
        turn(:turn_completed, opener: false)
        reason
        store.call(card("c"))
        rollback
        expect(listed.first[:turns_since]).to eq(0)
        turn(:turn_started, :turn_completed)
        expect(listed.first[:turns_since]).to eq(1)
      end

      it "keeps a replacement's count" do
        turn(:turn_started, :turn_completed)
        reason
        store.call(card("c"))
        store.call(card("c", "again"))
        turn(:turn_started, :turn_completed)
        expect(listed.first).to include(title: "again", turns_since: 1)
      end

      it "doesn't walk the messages to push a running turn's row (a save does, with a file)" do
        reads = 0
        counted = described_class.new(messages: lambda {
          reads += 1
          conversation
        })
        turn(:turn_started, on: counted)
        3.times { counted.call({ type: :hook_notice, hook: "h", text: "row", level: :info }) }
        expect(reads).to eq(0)
      end
    end

    it "a Continue's own card keeps its actions and its row: a kept Continue never has an opening" do
      turn(:turn_started, :turn_completed)
      turn(:turn_started, continue: true)
      store.call(card("own", in_turn: true).merge(actions: [{ label: "Nudge", command: "/x" }]))
      turn(:turn_completed, opener: false)
      expect(listed.first).to include(id: "own", in_turn: true, actions: [{ label: "Nudge", command: "/x" }], turns_since: 0)
    end

    it "a failed Continue's own card goes between turns, without its actions" do
      turn(:turn_started, :turn_completed)
      turn(:turn_started, continue: true)
      store.call(card("own", in_turn: true).merge(actions: [{ label: "Nudge", command: "/x" }]))
      turn(:turn_failed)
      expect(listed.first).to include(id: "own", in_turn: false, actions: [])
    end

    describe "the openings that count" do
      def before_it = store.call(card("before"))

      it "a task's, a context's and a delegate's wake: each opening moves an earlier card by 1, the place holds" do
        turn(:turn_started, :turn_completed)
        before_it
        [{ role: "system", kind: "note", turn_start: true }, { role: "system", kind: "note", turn_start: true },
         { role: "user", kind: "input", source: "delegate_report", turn_start: true }].each_with_index do |opener, n|
          conversation << opener.merge(content: "woke", turn_id: "w#{n}")
          store.call({ type: :turn_started, turn_id: "w#{n}", continue: true })
          store.call({ type: :turn_completed })
          expect(listed.first[:turns_since]).to eq(n + 1)
        end
      end

      it "an opening with no id (/continue no's reason) counts as on the page, a !cmd's record doesn't" do
        turn(:turn_started, :turn_completed)
        before_it
        turn(:turn_started, :turn_completed)
        conversation << { role: "user", content: "too slow" }
        conversation << { role: "user", content: "!(ls)\nfile" }
        expect(listed.first[:turns_since]).to eq(2)
        turn(:turn_started, :turn_completed)
        expect(listed.first[:turns_since]).to eq(3)
      end

      it "reads the first card on a session with turns from before this store: 0, then 1" do
        opened("older")
        before_it
        expect(listed.first[:turns_since]).to eq(0)
        turn(:turn_started, :turn_completed)
        expect(listed.first[:turns_since]).to eq(1)
      end

      it "doesn't count a running prompt turn: the page draws it from the running turn" do
        before_it
        turn(:turn_started)
        expect(listed.first[:turns_since]).to eq(0)
      end
    end

    it "a card replaced in place keeps its anchor" do
      turn(:turn_started, :turn_completed)
      store.call(card("a"))
      turn(:turn_started, :turn_completed)
      store.call(card("a", "again"))
      expect(listed.first).to include(title: "again", updated: true, turns_since: 1)
    end

    it "a between-turns notice while a turn runs goes after that turn, as a :during card does" do
      turn(:turn_started)
      store.call({ type: :hook_notice, hook: "h", text: "anytime", level: :info, between_turns: true })
      turn(:turn_completed)
      expect(listed.first).to include(in_turn: false, turns_since: 0)
      turn(:turn_started, :turn_completed)
      expect(listed.first[:turns_since]).to eq(1)
    end

    it "a held card shown idle reads above the next turn, never as a running one" do
      turn(:turn_started, :turn_completed)
      store.call(card("held", in_turn: true))
      expect(listed.first).to include(current: false, in_turn: true, turns_since: 0)
      turn(:turn_started)
      expect(listed.first[:current]).to be(false)
      turn(:turn_completed)
      expect(listed.first[:turns_since]).to eq(1)
    end

    it "lists an in-turn entry with no anchor as nobody's while nothing runs" do
      store.call(card("held", in_turn: true))
      expect(listed.first).to include(current: false, turns_since: 0)
      expect(store.list.first).to include(current: false)
    end

    it "lists no place without messages, nor steps a turn back" do
      turn(:turn_started)
      store.call(card("own", in_turn: true))
      turn(:turn_failed)
      expect(store.list.first).to include(in_turn: true, current: false)
      expect(store.list.first).not_to have_key(:turns_since)
    end

    it "keeps a load warning announced inside the first turn above that turn's prompt" do
      turn(:turn_started, :turn_completed)
      turn(:turn_started)
      store.call({ type: :guardrail_warning, message: "bad rule" })
      turn(:turn_completed)
      expect(listed.first).to include(type: :guardrail_warning, turns_since: 1)

      first = described_class.new(capacity: 3)
      first.call({ type: :turn_started, turn_id: "only" })
      first.call({ type: :guardrail_warning, message: "bad rule" })
      first.call({ type: :turn_completed })
      expect(first.list(messages: [{ role: "user", content: "p", turn_id: "only" }]).first[:turns_since]).to eq(1)
    end

    it "shows none of its internals" do
      turn(:turn_started, continue: true)
      store.call(card("own", in_turn: true))
      expect(listed.first.keys).not_to include(:turn_id, :continued, :base_since)
    end
  end

  describe "a CardStore saved in the session's folder" do
    let(:dir) { Dir.mktmpdir }
    let(:path) { File.join(dir, Samagotchi::Bridge::CardStore::FILE) }

    after { FileUtils.rm_rf(dir) }

    def card(id) = { type: :card, id: id, source: "loop-guard", title: id, body: "**why**", level: :warn, actions: [], in_turn: true }

    # One turn of loop-guard's: a notice in step 3, its card, the turn
    # canceled by the hook.
    def loop_turn(store)
      turn(:turn_started, on: store)
      store.call({ type: :generation_started, iteration: 3 })
      store.call({ type: :tool_call_started, iteration: 3, call_index: 1 })
      store.call({ type: :hook_notice, hook: "loop-guard", text: "loop: execute repeated, denied", level: :warn })
      store.call(card("stop"))
      turn(:turn_canceled, on: store)
    end

    def saved = Samagotchi::Bridge::CardStore.saved(dir, messages: conversation)

    it "lets a later store (a new worker) list a turn's card and notices where they were, and count on" do
      loop_turn(Samagotchi::Bridge::CardStore.new(path: path))
      later = Samagotchi::Bridge::CardStore.new(path: path)
      expect(listed(later)).to eq([
        { type: :hook_notice, hook: "loop-guard", text: "loop: execute repeated, denied", level: "warn", in_turn: true,
          iteration: 3, calls: 1, earlier: true, turns_since: 0, current: false },
        { type: :card, id: "stop", source: "loop-guard", title: "stop", body: "**why**", level: "warn", actions: [],
          in_turn: true, earlier: true, turns_since: 0, current: false }
      ])
      turn(:turn_started, :turn_completed, on: later)
      expect(listed(later).map { |entry| entry[:turns_since] }).to eq([1, 1])
      expect(saved.map { |entry| entry[:turns_since] }).to eq([1, 1])
    end

    it "lists them for a session no worker runs (.saved), as a store with no turn running" do
      store = Samagotchi::Bridge::CardStore.new(path: path)
      turn(:turn_started, on: store)
      store.call(card("mid"))
      expect(saved).to contain_exactly(include(id: "mid", turns_since: 0, current: false))
    end

    it "saves neither the load warnings (each worker announces its own) nor a question still open" do
      store = Samagotchi::Bridge::CardStore.new(path: path)
      store.call({ type: :guardrail_warning, message: "bad rule", label: "guardrails" })
      turn(:turn_started, on: store)
      store.call({ type: :question_requested, pending_question: { id: "q1", question: "Which?", status: "pending" } })
      store.call({ type: :question_requested, pending_question: { id: "q2", question: "Allow?", status: "pending" } })
      store.call({ type: :question_answered, id: "q2", answer: { selected: ["yes"] } })
      opened(@running_id) # still running on disk: the checkpoint has its prompt
      expect(saved).to contain_exactly(
        include(type: :question, pending_question: include(id: "q2"), answer: { selected: ["yes"] })
      )
    end

    it "keeps the caps across workers: a seeded store evicts its oldest like an in-memory one" do
      Samagotchi::Bridge::CardStore.new(capacity: 2, path: path).tap { |store| %w[a b].each { |id| store.call(card(id)) } }
      later = Samagotchi::Bridge::CardStore.new(capacity: 2, path: path)
      later.call(card("c"))
      expect(later.list.map { |entry| entry[:id] }).to eq(%w[b c])
      expect(JSON.parse(File.read(path))["entries"].size).to eq(2)
    end

    it "seeds an earlier in-turn card without its actions; a between-turns card keeps them" do
      nudge = [{ label: "Nudge", command: "/checkin nudge" }]
      offer = [{ label: "Attach", command: "/pr-attach 1" }]
      store = Samagotchi::Bridge::CardStore.new(path: path)
      turn(:turn_started, on: store)
      store.call(card("check").merge(actions: nudge))
      turn(:turn_completed, on: store)
      store.call(card("offer").merge(actions: offer, in_turn: false))

      expect(store.list.to_h { |entry| [entry[:id], entry[:actions]] }).to eq("check" => nudge, "offer" => offer)
      later = Samagotchi::Bridge::CardStore.new(path: path)
      expect(later.list.to_h { |entry| [entry[:id], entry[:actions]] })
        .to eq("check" => [], "offer" => offer)
      expect(saved.to_h { |entry| [entry[:id], entry[:actions]] })
        .to eq("check" => [], "offer" => offer)
    end

    # A worker's store (the Bridge's): the session file keeps a running turn's
    # prompt (TurnCheckpoint) with its id, so a turn a kill cut short counts by
    # its opening, with nothing saved about it.
    describe "a worker killed in a turn" do
      def worker_store = Samagotchi::Bridge::CardStore.new(path: path)
      def between(id) = card(id).merge(in_turn: false, level: :info)

      # The kill: the checkpoint's prompt stays in the session's messages.
      def killed
        opened(@running_id)
        @running_id = nil
      end

      it "counts the turn, with nothing saved about it: a card before it goes above its prompt, for good" do
        worker_store.tap do |store|
          store.call(between("before"))
          turn(:turn_started, on: store)
        end
        expect(JSON.parse(File.read(path))).not_to have_key("running")
        killed
        later = worker_store
        expect(listed(later).first).to include(id: "before", turns_since: 1, current: false)
        expect(saved.first).to include(turns_since: 1)
        turn(:turn_started, :turn_completed, on: later)
        expect(listed(later).first[:turns_since]).to eq(2)
      end

      it "keeps the killed turn's own card with it, and an anytime command's after it" do
        worker_store.tap do |store|
          turn(:turn_started, on: store)
          store.call(card("own"))
          store.call(between("btw"))
        end
        killed
        later = worker_store
        expect(listed(later).map { |c| [c[:id], c[:turns_since], c[:current]] }).to eq([["own", 0, false], ["btw", 0, false]])
        expect(listed(later).last).not_to have_key(:during)
        turn(:turn_started, on: later)
        expect(listed(later).map { |c| [c[:id], c[:current]] }).to eq([["own", false], ["btw", false]])
        turn(:turn_completed, on: later)
        expect(listed(later).map { |c| c[:turns_since] }).to eq([1, 1])
      end

      it "counts it once however many stores start from the file, and each killed turn" do
        worker_store.tap do |store|
          store.call(between("before"))
          turn(:turn_started, on: store)
        end
        killed
        expect(Array.new(3) { listed(worker_store).first[:turns_since] }).to eq([1, 1, 1])
        turn(:turn_started, on: worker_store)
        killed
        expect(listed(worker_store).first[:turns_since]).to eq(2)
      end

      it "doesn't count a kill before the turn began, or a REPL's kill: the prompt isn't in the session" do
        worker_store.tap do |store|
          store.call(between("before"))
          turn(:turn_started, on: store)
        end
        @running_id = nil
        expect(listed(worker_store).first[:turns_since]).to eq(0)
      end

      it "doesn't count a turn that failed and went back before the kill" do
        worker_store.tap do |store|
          store.call(between("before"))
          turn(:turn_started, :turn_failed, on: store)
        end
        expect(listed(worker_store).first[:turns_since]).to eq(0)
      end

      it "writes no file for a session with no entries" do
        turn(:turn_started, on: worker_store)
        expect(File.exist?(path)).to be(false)
      end
    end

    describe "a card shown after a failed turn's prompt went back" do
      def between(id) = card(id).merge(in_turn: false, level: :info)

      it "saves the mark at the failed turn's end, with nothing else" do
        store = Samagotchi::Bridge::CardStore.new(path: path)
        store.call(between("before"))
        turn(:turn_started, :turn_failed, on: store)
        expect(JSON.parse(File.read(path))["failed_turn"]).to eq("t1")
      end

      it "keeps the mark when it's replaced" do
        store = Samagotchi::Bridge::CardStore.new
        turn(:turn_started, :turn_failed, on: store)
        store.call(between("after"))
        store.call(between("after").merge(title: "again"))
        expect(listed(store).first).to include(title: "again", after_failed: true)
      end

      it "says so (the page draws that prompt at the end), saved, until the next turn starts" do
        store = Samagotchi::Bridge::CardStore.new(path: path)
        store.call(between("before"))
        turn(:turn_started, :turn_failed, on: store)
        store.call(between("after"))
        store.call({ type: :hook_notice, hook: "h", text: "note", level: :info, between_turns: true })
        expect(listed(store).map { |c| c[:after_failed] }).to eq([nil, true, true])
        expect(JSON.parse(File.read(path))["failed_turn"]).to eq("t1")
        expect(saved.map { |c| c[:after_failed] }).to eq([nil, true, true])

        turn(:turn_started, on: store)
        expect(listed(store).map { |c| c[:after_failed] }).to eq([nil, nil, nil])
        expect(JSON.parse(File.read(path))).not_to have_key("failed_turn")
      end

      it "never marks a failed turn's own card, nor a :during one" do
        store = Samagotchi::Bridge::CardStore.new
        turn(:turn_started, on: store)
        store.call(card("own"))
        store.call(between("btw"))
        turn(:turn_failed, on: store)
        expect(listed(store).map { |c| c[:after_failed] }).to eq([nil, nil])
      end

      it "doesn't move an older card below a newer failed prompt" do
        store = Samagotchi::Bridge::CardStore.new
        turn(:turn_started, :turn_failed, on: store)
        store.call(between("after"))
        turn(:turn_started, :turn_failed, on: store)
        expect(listed(store).first[:after_failed]).to be_nil
        store.call(between("later"))
        expect(listed(store).map { |c| c[:after_failed] }).to eq([nil, true])
      end

      it "isn't for a failed turn that kept its steps: its prompt stays in the history" do
        store = Samagotchi::Bridge::CardStore.new
        turn(:turn_started, on: store)
        failed_keeping_steps(on: store)
        store.call(between("after"))
        expect(listed(store).first).not_to have_key(:after_failed)
      end
    end

    describe "the file (version 2)" do
      def worker(**options) = Samagotchi::Bridge::CardStore.new(path: path, messages: -> { conversation }, **options)

      it "reads the same after a restart as live, across an opening with no id" do
        store = worker
        turn(:turn_started, :turn_completed, on: store)
        turn(:turn_started, on: store, continue: true)
        store.call(card("own"))
        turn(:turn_completed, on: store, opener: false)
        conversation << { role: "user", content: "too slow" }
        expect(listed(store).first[:turns_since]).to eq(1)
        # The log keeps the opening the Continue's entry counts from.
        expect(JSON.parse(File.read(path))["turn_log"]).to eq(%w[t1 t2])
        expect(saved.first[:turns_since]).to eq(1)
        expect(listed(worker).first[:turns_since]).to eq(1)
      end

      it "writes at a turn's end with nothing else: a :during card's flag goes" do
        store = worker
        store.call(card("own").merge(in_turn: false))
        turn(:turn_started, on: store)
        store.call(card("btw").merge(in_turn: false))
        expect(JSON.parse(File.read(path))["entries"].last).to include("during" => true)
        turn(:turn_failed, on: store)
        expect(JSON.parse(File.read(path))["entries"].last).not_to have_key("during")
      end

      it "refuses an entry whose saved place isn't a count or an id, keeping the rest" do
        good = { type: "card", id: "good", in_turn: false, turn_id: nil, base_since: 1 }
        File.write(path, JSON.generate({ version: 2, turn_log: [], entries: [
          good, good.merge(id: "list", base_since: [1]), good.merge(id: "negative", base_since: -1),
          good.merge(id: "text", base_since: "1"), good.merge(id: "past", past_idless: [1]), good.merge(id: "backwards", past_idless: -1),
          good.merge(id: "anchor", turn_id: [1])
        ] }))
        expect(saved.map { |c| [c[:id], c[:turns_since]] }).to eq([["good", 1]])
      end

      it "holds the log and the entries, nothing of a running turn; a later store reads it back" do
        store = Samagotchi::Bridge::CardStore.new(path: path)
        store.call(card("before").merge(in_turn: false))
        turn(:turn_started, on: store)
        data = JSON.parse(File.read(path))
        expect(data).to include("version" => 2, "turn_log" => ["t1"])
        expect(data.keys).to contain_exactly("version", "turn_log", "entries")
        expect(data["entries"].first).to include("id" => "before", "turn_id" => nil)
        expect(data["entries"].first).not_to have_key("turns")
        turn(:turn_completed, on: store)
        expect(saved.first).to include(id: "before", turns_since: 1, earlier: true)
      end

      it "prunes the log to the earliest anchor, and keeps it whole for an entry with none" do
        store = worker
        turn(:turn_started, :turn_completed, on: store)
        turn(:turn_started, :turn_completed, on: store)
        store.call(card("second").merge(in_turn: false))
        turn(:turn_started, :turn_completed, on: store)
        expect(JSON.parse(File.read(path))["turn_log"]).to eq(%w[t2 t3])
        store.call(card("third").merge(in_turn: false))
        expect(JSON.parse(File.read(path))["turn_log"]).to eq(%w[t2 t3])
        expect(saved.map { |c| c[:turns_since] }).to eq([1, 0])
        expect(listed(worker).map { |c| c[:turns_since] }).to eq([1, 0])

        none = File.join(dir, "none.json")
        whole = Samagotchi::Bridge::CardStore.new(path: none, messages: -> { conversation })
        whole.call(card("first").merge(in_turn: false))
        turn(:turn_started, :turn_completed, on: whole)
        turn(:turn_started, :turn_completed, on: whole)
        expect(JSON.parse(File.read(none))["turn_log"]).to eq(%w[t4 t5])
      end

      it "keeps the whole log with no messages to find an anchor's opening in" do
        store = Samagotchi::Bridge::CardStore.new(path: path)
        turn(:turn_started, :turn_completed, on: store)
        store.call(card("late").merge(in_turn: false))
        turn(:turn_started, :turn_completed, on: store)
        expect(JSON.parse(File.read(path))["turn_log"]).to eq(%w[t1 t2])
      end

      it "an old entry holds the log from its anchor, whatever came after it" do
        store = Samagotchi::Bridge::CardStore.new(path: path, capacity: 5)
        turn(:turn_started, :turn_completed, on: store)
        store.call(card("first").merge(in_turn: false))
        turn(:turn_started, :turn_completed, on: store)
        store.call({ type: :hook_notice, hook: "h", text: "later", level: :info })
        store.call(card("first").merge(in_turn: false, title: "again"))
        expect(JSON.parse(File.read(path))["turn_log"]).to eq(%w[t1 t2])
      end

      it "a failed turn's left-nothing read holds after a restart" do
        store = Samagotchi::Bridge::CardStore.new(path: path)
        turn(:turn_started, on: store)
        store.call(card("own").merge(actions: [{ label: "Go", command: "/go" }]))
        store.call({ type: :empty_answer_retry, attempt: 1, of: 1 })
        turn(:turn_failed, on: store)
        expect(saved).to contain_exactly(include(id: "own", in_turn: false, actions: [], turns_since: 0, current: false))
      end
    end

    describe "a file from before the log (version 1)" do
      def v1(turns:, entries:, **extra) = File.write(path, JSON.generate({ version: 1, turns: turns, entries: entries, **extra }))
      def old(id, turns, **rest) = { type: "card", id: id, source: "b", title: id, body: "", in_turn: false, actions: [], turns: turns, **rest }

      it "keeps its places, with no running turn: a new opening adds 1; the next save writes version 2" do
        v1(turns: 3, entries: [old("a", 1), old("b", 3), old("own", 2, in_turn: true)])
        expect(saved.map { |c| [c[:id], c[:turns_since], c[:current]] }).to eq([["a", 2, false], ["b", 0, false], ["own", 0, false]])
        expect(JSON.parse(File.read(path))["version"]).to eq(1) # a read writes nothing

        later = Samagotchi::Bridge::CardStore.new(path: path)
        turn(:turn_started, on: later)
        expect(JSON.parse(File.read(path))).to include("version" => 2, "turn_log" => ["t1"])
        expect(listed(later).map { |c| [c[:id], c[:current]] }).to eq([["a", false], ["b", false], ["own", false]])
        turn(:turn_completed, on: later)
        expect(listed(later).map { |c| c[:turns_since] }).to eq([3, 1, 1])
        expect(saved.map { |c| c[:turns_since] }).to eq([3, 1, 1])
      end

      it "counts a turn the file says its worker was killed in, and a :during card after it" do
        v1(turns: 2, running: true, entries: [old("before", 2), old("btw", 2, during: true), old("own", 2, in_turn: true)])
        expect(saved.map { |c| [c[:id], c[:turns_since], c[:current]] }).to eq([["before", 1, false], ["btw", 0, false], ["own", 0, false]])
        expect(saved[1]).not_to have_key(:during)
      end

      it "never reads an old in-turn entry as left nothing: it has no id to check" do
        v1(turns: 1, entries: [old("own", 0, in_turn: true, actions: [{ label: "Go", command: "/go" }]),
                               { type: "hook_notice", hook: "h", text: "row", in_turn: true, iteration: 2, calls: 0, turns: 0 }])
        expect(saved).to contain_exactly(include(id: "own", in_turn: true, actions: [], turns_since: 0, current: false),
                                         include(text: "row", in_turn: true, iteration: 2, turns_since: 0, current: false))
      end

      it "skips an entry with no integer turns; a card replaced later keeps its place" do
        v1(turns: 2, entries: [old("a", 1), { type: "card", id: "x" }])
        later = Samagotchi::Bridge::CardStore.new(path: path)
        later.call(card("a").merge(in_turn: false))
        expect(listed(later).map { |c| [c[:id], c[:turns_since]] }).to eq([["a", 1]])
        expect(JSON.parse(File.read(path))["entries"].first).to include("base_since" => 1)
      end
    end

    it "starts empty from a missing, broken or foreign file" do
      expect(saved).to eq([])
      File.write(path, "{not json")
      expect(saved).to eq([])
      File.write(path, JSON.generate({ "entries" => "x" }))
      expect(saved).to eq([])
    end
  end

  describe "a CardStore over real Engine turns" do
    let(:store) { Samagotchi::Bridge::CardStore.new(messages: -> { session.messages }) }
    let(:flow) { Samagotchi::TurnFlow.new(engine: engine) }

    before do
      allow(kernel).to receive(:run) do |messages, **|
        Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages + [{ role: "model", content: "ok" }])
      end
      engine.subscribe(observer: store)
      engine.session = session
    end

    def real_turn(prompt, **options) = engine.run_turn(session, prompt, **options)
    def since(id = "c") = store.list(messages: session.messages).find { |e| e[:id] == id }[:turns_since]

    def wake
      id = SecureRandom.uuid
      engine.add_context_note(session, { note_id: "task-#{id}", source: "task x", header: Samagotchi::ContextNote::TASK_HEADER, text: "done",
                                         created_at: Time.now.iso8601, turn_start: true, turn_id: id })
      flow.before_prompt_turn
      real_turn(nil, continue: true, id: id)
    end

    def stopped_controller = Samagotchi::CancellationController.new.tap { |c| c.cancel!(:user) }

    # The count the page's turnPromptBubbles makes of the same messages:
    # bubbles.test.js pins that it takes what Steer.turn_opening? does.
    it "agrees with the openings in the messages through continue, prompt, wake, !cmd, stop and !rollback" do
      real_turn("one")
      engine.show_card(source: "b", id: "c", title: "c")
      expect(since).to eq(0)

      real_turn(nil, continue: true)
      expect(since).to eq(0)
      flow.before_prompt_turn
      real_turn("two")
      expect(since).to eq(1)
      engine.show_card(source: "b", id: "after-two", title: "after")
      flow.rollback!
      expect([since, since("after-two")]).to eq([0, 0])

      wake
      expect(since).to eq(1)
      flow.rollback! # the wake's note stays, counted
      expect(since).to eq(1)
      engine.append_messages([{ role: "user", content: "!(ls)\nfile" }])
      expect(since).to eq(1)
      real_turn("stopped", cancel_controller: stopped_controller)
      expect(since).to eq(1)
      real_turn("three")
      expect(since).to eq(2)
      expect(since("after-two")).to eq(2)
      openings = session.messages.count { |m| Samagotchi::Steer.turn_opening?(m) }
      expect(openings).to eq(3) # one, the wake's note, three
    end

    it "a card shown after a Continue's /continue no stays below the reason" do
      real_turn("one")
      real_turn(nil, continue: true)
      flow.abort_continue!(reason: "too slow")
      engine.show_card(source: "b", id: "c", title: "c")
      expect(since).to eq(0)
      real_turn("next")
      expect(since).to eq(1)
    end

    it "a /continue no's reason counts, with no id" do
      real_turn("one")
      engine.show_card(source: "b", id: "c", title: "c")
      real_turn("two")
      flow.abort_continue!(reason: "too slow")
      real_turn("three")
      expect(since).to eq(session.messages.count { |m| Samagotchi::Steer.turn_opening?(m) } - 1)
      expect(since).to eq(3)
    end

    it "a warning the Engine announces inside the first turn stays above its prompt" do
      engine.register_hook(:before_turn) { |_e| store.call({ type: :guardrail_warning, message: "bad rule" }) }
      real_turn("one")
      expect(store.list(messages: session.messages).first).to include(type: :guardrail_warning, turns_since: 1)
    end

    it "a failed turn with nothing kept: its card stays above the next prompt, no actions, its other rows gone" do
      allow(kernel).to receive(:run).and_raise("boom")
      engine.register_hook(:before_turn) do |_e|
        engine.show_card(source: "b", id: "c", title: "own", actions: [{ label: "Go", command: "/go" }])
        store.call({ type: :empty_answer_retry, attempt: 1, of: 1 })
      end
      begin
        real_turn("failed")
      rescue StandardError
        nil
      end
      session.messages.reject! { |m| m[:content] == "failed" } # Worker#restore_failed_turn
      expect(store.list(messages: session.messages)).to contain_exactly(include(id: "c", in_turn: false, actions: [], turns_since: 0))
    end
  end

  describe "the Bridge's snapshot" do
    it "counts a turn its worker was killed in, when a later worker's Bridge starts" do
      state_dir = Dir.mktmpdir
      engine.session = session
      bridge = Samagotchi::Bridge.new(engine: engine, state_dir: state_dir, session_id: "s1")
      engine.subscribe(observer: bridge.instance_variable_get(:@cards))
      engine.show_card(source: "b", title: "one", id: "c1")
      bridge.instance_variable_get(:@cards).call({ type: :turn_started, turn_id: "t1" })
      session.messages << { role: "user", content: "killed", turn_id: "t1" }
      later = Samagotchi::Bridge.new(engine: engine, state_dir: state_dir, session_id: "s1")
      expect(later.snapshot[:cards].first).to include(id: "c1", turns_since: 1)
    end

    it "lists against the messages the snapshot carries: a running wake's note is in both, a running prompt in neither" do
      state_dir = Dir.mktmpdir
      engine.session = session
      bridge = Samagotchi::Bridge.new(engine: engine, state_dir: state_dir, session_id: "s1")
      store = bridge.instance_variable_get(:@cards)
      engine.subscribe(observer: store)
      engine.show_card(source: "b", title: "one", id: "c1")
      store.call({ type: :turn_started, turn_id: "running" })
      expect(bridge.snapshot[:cards].first[:turns_since]).to eq(0)
      expect(bridge.tail_frame[:cards].first[:turns_since]).to eq(0)
      store.call({ type: :turn_canceled })
      session.messages << { role: "system", kind: "note", content: "done", turn_start: true, turn_id: "wake" }
      store.call({ type: :turn_started, turn_id: "wake", continue: true })
      snapshot = bridge.snapshot
      expect(snapshot[:messages].count { |m| Samagotchi::Steer.turn_opening?(m) }).to eq(1)
      expect(snapshot[:cards].first[:turns_since]).to eq(1)
      expect(bridge.tail_frame[:cards].first[:turns_since]).to eq(1)
    end

    it "carries the cards" do
      bridge = Samagotchi::Bridge.new(engine: engine, state_dir: Dir.mktmpdir, session_id: "s1")
      engine.subscribe(observer: bridge.instance_variable_get(:@cards))
      engine.show_card(source: "b", title: "one", id: "c1")
      expect(bridge.snapshot[:cards].map { |c| c[:id] }).to eq(["c1"])
    end

    it "saves them in the session's folder, and a later worker's Bridge starts from them" do
      state_dir = Dir.mktmpdir
      bridge = Samagotchi::Bridge.new(engine: engine, state_dir: state_dir, session_id: "s1")
      engine.subscribe(observer: bridge.instance_variable_get(:@cards))
      engine.show_card(source: "b", title: "one", id: "c1")
      expect(Samagotchi::Bridge::CardStore.saved(File.join(state_dir, "s1")).map { |c| c[:id] }).to eq(["c1"])

      later = Samagotchi::Bridge.new(engine: Samagotchi::Engine.new(client: client, kernel: kernel), state_dir: state_dir,
                                     session_id: "s1")
      expect(later.snapshot[:cards].map { |c| c[:id] }).to eq(["c1"])
    ensure
      FileUtils.rm_rf(state_dir) if state_dir
    end
  end
end
