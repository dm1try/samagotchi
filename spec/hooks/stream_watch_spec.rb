# frozen_string_literal: true

require "samagotchi/hooks"
require "samagotchi/cancellation_controller"
require "samagotchi/log"
require "fileutils"
require "tmpdir"

RSpec.describe Samagotchi::Hooks::StreamWatch do
  let(:registry) { Samagotchi::Hooks::Registry.new }
  let(:controller) { Samagotchi::CancellationController.new }
  let(:now) { [0.0] }
  let(:watch) { described_class.new(hooks: registry, cancel_controller: controller, clock: -> { now.first }) }
  let(:fires) { [] }

  before { registry.register(:generation_progress) { |event| fires << event } }

  it "batches a long stream: at most one fire per 2000 chars, the deltas adding up to the stream" do
    thinking = +""
    text = +""
    watch.started(1)
    (200_000 / 7).times do |i|
      chunk = format("%06d ", i)
      i.even? ? thinking << chunk : text << chunk
      watch.feed(thinking: i.even? ? chunk : "", text: i.even? ? "" : chunk)
    end

    expect(fires.size).to be_between(99, 101)
    expect(fires.map { |e| e[:thinking] }.join).to eq(thinking[0, fires.sum { |e| e[:thinking].length }])
    expect(fires.map { |e| e[:text] }.join).to eq(text[0, fires.sum { |e| e[:text].length }])
    expect(fires.last).to include(iteration: 1, thinking_chars: fires.sum { |e| e[:thinking].length })
    expect(fires.first[:thinking]).to be_frozen
    expect(thinking.length + text.length - fires.sum { |e| e[:thinking].length + e[:text].length }).to be < 2000
  end

  it "fires what is pending once a second has passed, with the time since the generation started" do
    watch.started(2)
    watch.feed(thinking: "Let me think.", text: "")
    now[0] = 0.5
    watch.feed(thinking: " More.", text: "")
    expect(fires).to be_empty

    now[0] = 1.0
    watch.feed(thinking: "", text: "Hi")

    expect(fires.size).to eq(1)
    expect(fires.first).to include(type: :generation_progress, iteration: 2, thinking: "Let me think. More.", text: "Hi",
                                   thinking_chars: 19, text_chars: 2, elapsed_ms: 1000)
    now[0] = 3.0
    watch.feed(thinking: "", text: "")
    expect(fires.size).to eq(1)
  end

  it "starts each generation over" do
    watch.started(1)
    watch.feed(thinking: "a" * 1500, text: "")
    watch.started(2)
    watch.feed(thinking: "b" * 1500, text: "")
    expect(fires).to be_empty

    watch.feed(thinking: "b" * 500, text: "")
    expect(fires.first).to include(iteration: 2, thinking: "b" * 2000, thinking_chars: 2000)
  end

  it "fires nothing once the turn is cancelled" do
    watch.started(1)
    controller.cancel!(:user)
    watch.feed(thinking: "x" * 5000, text: "")

    expect(fires).to be_empty
  end

  it "fires nothing once the generation is cut (lines read after the socket closed)" do
    controller.generation do
      watch.started(1)
      watch.feed(thinking: "x" * 2000, text: "")
      controller.cancel_generation!(:hook, { by: "b", reason: "r" })
      watch.feed(thinking: "x" * 5000, text: "")
    end

    expect(fires.size).to eq(1)
  end

  it "fires nothing before a generation started" do
    watch.feed(thinking: "x" * 5000, text: "")

    expect(fires).to be_empty
  end

  it "gives the hook stop_generation, and an ask_user that asks no one" do
    asked = []
    registry.runtime = Samagotchi::Hooks::Runtime.new(
      ask_user: ->(**question) { asked << question },
      stop_generation: lambda { |reason:, hook:|
        asked << [reason, hook]
        true
      }
    )
    answers = []
    registry.register(:generation_progress) do |event|
      answers << event[:ask_user].call(question: "go on?", options: %w[yes no])
      answers << event[:stop_generation].call("loops")
    end
    watch.started(1)
    watch.feed(thinking: "x" * 2000, text: "")

    expect(answers).to eq([nil, true])
    expect(asked).to eq([["loops", "turn hook"]])
  end

  describe "a slow or broken hook" do
    let(:dir) { Dir.mktmpdir("samagotchi-log") }
    let(:path) { File.join(dir, "chi.log") }

    before { Samagotchi::Log.configure(path: path) }
    after { FileUtils.remove_entry(dir) }

    def records = File.exist?(path) ? File.readlines(path) : []

    it "logs stream_hook_slow once per turn, and keeps firing" do
      registry.register(:generation_progress) { now[0] += 0.15 }
      watch.started(1)
      3.times { watch.feed(thinking: "x" * 2000, text: "") }

      expect(fires.size).to eq(3)
      slow = records.grep(/stream_hook_slow/)
      expect(slow.size).to eq(1)
      expect(slow.first).to include("ms=150", %(hook="turn hook"))
    end

    it "keeps firing after a hook raised" do
      registry.register(:generation_progress) { raise "boom" }
      watch.started(1)
      3.times { watch.feed(thinking: "x" * 2000, text: "") }

      expect(fires.size).to eq(3)
    end
  end
end
