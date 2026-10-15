# frozen_string_literal: true

require "spec_helper"
require "samagotchi/event_routes"

# EventRoutes: the five routes of a card or a notice, first match wins, each
# with the caller's marks; #route_by_turn only the last two.
RSpec.describe Samagotchi::EventRoutes do
  # A fake Engine: each lookup reads a flag, each route records what it got.
  let(:calls) { [] }
  let(:held_store) { [] }
  let(:flags) { { loading: false, anytime: false, init: false, running: false } }
  let(:extension_load) do
    store = held_store
    flag = flags
    Struct.new(:x) do
      define_method(:loading?) { flag[:loading] }
      define_method(:hold) { |event| store << event }
    end.new
  end
  let(:routes) do
    described_class.new(
      extension_load: -> { extension_load },
      in_turn_sink: -> { [flags[:running], :the_sink] },
      anytime_thread: -> { flags[:anytime] },
      init_task: -> { flags[:init] ? :a_task : nil },
      announce: ->(event) { calls << [:announce, event] },
      announce_anytime: ->(event) { calls << [:announce_anytime, event] },
      announce_or_hold: ->(event) { calls << [:announce_or_hold, event] },
      emit: ->(sink, event) { calls << [:emit, sink, event] }
    )
  end
  let(:event) { { type: :card, id: "c1" } }

  # [flags set, route, what it calls] — first match wins: each row sets its
  # own flag and every flag of the rows below it.
  [
    [%i[loading anytime init running], :held],
    [%i[anytime init running], :anytime],
    [%i[init running], :init],
    [%i[running], :in_turn],
    [[], :between]
  ].each do |set, route|
    it "takes the #{route} route when #{set.empty? ? "nothing else applies" : set.join(", ")}" do
      set.each { |flag| flags[flag] = true }

      expect(routes.route(event, **described_class::CARD_MARKS)).to eq(route)
      expect(routes.route(event, **described_class::NOTICE_MARKS)).to eq(route)
    end
  end

  it "marks a card on each route" do
    m = described_class::CARD_MARKS
    flags[:loading] = true
    routes.route(event, **m)
    expect(held_store).to eq([event.merge(in_turn: true)])

    flags[:loading] = false
    flags[:anytime] = true
    routes.route(event, **m)
    flags[:anytime] = false
    flags[:init] = true
    routes.route(event, **m)
    flags[:init] = false
    flags[:running] = true
    routes.route(event, **m)
    flags[:running] = false
    routes.route(event, **m)

    expect(calls).to eq([[:announce_anytime, event.merge(in_turn: false)], [:announce, event.merge(in_turn: false)],
                         [:emit, :the_sink, event.merge(in_turn: true)], [:announce_or_hold, event.merge(in_turn: false)]])
  end

  it "marks a notice only outside a turn" do
    notice = { type: :hook_notice, text: "n" }
    m = described_class::NOTICE_MARKS
    flags[:loading] = true
    routes.route(notice, **m)
    expect(held_store).to eq([notice])

    flags[:loading] = false
    flags[:anytime] = true
    routes.route(notice, **m)
    flags[:anytime] = false
    flags[:init] = true
    routes.route(notice, **m)
    flags[:init] = false
    flags[:running] = true
    routes.route(notice, **m)
    flags[:running] = false
    routes.route(notice, **m)

    between = notice.merge(between_turns: true)
    expect(calls).to eq([[:announce_anytime, between], [:announce, between], [:emit, :the_sink, notice],
                         [:announce_or_hold, between]])
  end

  it "leaves the caller's event as it was" do
    flags[:running] = true
    routes.route(event, **described_class::CARD_MARKS)
    expect(event).to eq(type: :card, id: "c1")
  end

  describe "#route_by_turn" do
    it "ignores the load, an anytime thread and an init task: a running turn's event, else announced or held, unmarked" do
      flags.merge!(loading: true, anytime: true, init: true)
      expect(routes.route_by_turn(event)).to eq(:between)
      flags[:running] = true
      expect(routes.route_by_turn(event)).to eq(:in_turn)

      expect(held_store).to be_empty
      expect(calls).to eq([[:announce_or_hold, event], [:emit, :the_sink, event]])
    end
  end
end
