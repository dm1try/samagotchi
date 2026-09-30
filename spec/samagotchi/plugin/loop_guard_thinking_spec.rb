# frozen_string_literal: true

require "spec_helper"
require "samagotchi/hooks"

# loop-guard's thinking watch (lib/samagotchi/bundles/loop-guard): the
# :generation_progress hook sees streamed thinking go round in the same few
# sentences, cuts the generation (stop_generation) and, if the retry loops
# too, stops the turn with a card. The detector is fed the fixtures in
# spec/fixtures/loop_guard/thinking: positives (a loop_start and cycle_chars
# header) must trigger within one batch of the loop's third cycle,
# negatives never.
RSpec.describe "The loop-guard thinking watch" do
  let(:source) { File.expand_path("../../../lib/samagotchi/bundles/loop-guard/plugin.rb", __dir__) }
  let(:fixtures) { File.expand_path("../../fixtures/loop_guard/thinking", __dir__) }
  let(:mod) { Module.new.tap { |m| m.module_eval(File.read(source), source) } }
  let(:batch) { Samagotchi::Hooks::StreamWatch::EVERY_CHARS }

  # A fixture's text, its header lines ("# key: value") dropped and read.
  def fixture(name)
    lines = File.read(File.join(fixtures, name)).split("\n", -1)
    header = {}
    while lines.first&.start_with?("#")
      key, value = lines.shift.delete_prefix("# ").split(": ", 2)
      header[key] = value.to_i if value&.match?(/\A\d+\z/)
    end
    [lines.join("\n"), header]
  end

  def watch(settings = {}) = mod::ThinkingWatch.new(mod::ThinkingWatch.settings(settings))

  # Feeds +text+ in +size+-char deltas; the char offset of the first loop
  # (and the loop), or nil.
  def first_loop(text, settings = {}, size: 64)
    detector = watch(settings)
    offset = 0
    text.each_char.each_slice(size) do |slice|
      offset += slice.size
      found = detector.feed(slice.join)
      return [offset, found] if found
    end
    nil
  end

  # 200k chars of distinct sentences, seeded (N3).
  def random_thinking(chars)
    rng = Random.new(3)
    words = %w[the file model test turn config value cache index thread lock stream answer reply request server
               session plugin hook event error retry change check look think maybe because while after before]
    text = +""
    text << "#{Array.new(rng.rand(6..16)) { words.sample(random: rng) }.join(" ").capitalize}. " while text.length < chars
    text
  end

  describe "the detector" do
    %w[exact_sentence.txt cycle3.txt cycle3_varied.txt pingpong.txt cycle_late.txt].each do |name|
      it "cuts #{name} within one batch of its third cycle" do
        text, header = fixture(name)
        third = header.fetch("loop_start") + (3 * header.fetch("cycle_chars"))

        offset, found = first_loop(text)

        expect(offset).to be_between(third, third + batch)
        expect(found.times).to be >= 3
      end
    end

    %w[calm_long.txt enumeration.txt real_runaway_numbers.txt].each do |name|
      it "never triggers on #{name}" do
        expect(first_loop(fixture(name).first)).to be_nil
      end
    end

    # A known gap: a runaway list of numbers has no sentence boundaries.
    it "doesn't see a runaway comma list of numbers (real Qwen3-0.6B, finish=length)" do
      text, = fixture("real_runaway_numbers.txt")

      expect(text[-2000..].count(".")).to eq(0)
      expect(first_loop(text)).to be_nil
    end

    # Borderline and kept: circular re-checking that would have ended by
    # itself with an answer after 36 s. The same sentence the 8th time.
    it "cuts the real Qwen3-0.6B re-checking on its 8th same sentence, halfway through" do
      text, = fixture("real_dither_x3y3.txt")

      offset, found = first_loop(text)

      expect(offset).to be_between(10_000, 15_000)
      expect(found).to have_attributes(period: 1, times: 8)
    end

    it "never triggers on 200k chars of distinct sentences, and stays cheap" do
      text = random_thinking(200_000)
      detector = watch
      slowest = 0.0
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      text.each_char.each_slice(batch) do |slice|
        fire = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect(detector.feed(slice.join)).to be_nil
        slowest = [slowest, Process.clock_gettime(Process::CLOCK_MONOTONIC) - fire].max
      end

      # Generous bounds: shared CI runners (and parallel spec processes)
      # stall for tens of ms; a real regression is an order of magnitude
      # (a batch costs ~1-2 ms on a quiet machine).
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2.0
      expect(slowest).to be < 0.25
    end

    it "triggers nothing before min_chars of thinking" do
      expect(first_loop("Let me write the reply to the user now. " * 12)).to be_nil
      expect(first_loop("Let me write the reply to the user now. " * 60)).not_to be_nil
    end

    describe "red-checks: the enumeration (N2) is a near miss" do
      it "triggers without the minimum loop span (its code repeats one guard line)" do
        _offset, found = first_loop(fixture("enumeration.txt").first, { "min_span_sentences" => 1, "min_span_chars" => 1 })

        expect(found.sentences.first).to start_with("raise ArgumentError")
      end

      it "triggers at similarity 0.3 (its templated path sentences)" do
        _offset, found = first_loop(fixture("enumeration.txt").first, { "similarity" => 0.3 })

        expect(found.sentences.first).to start_with("Now I need to open the file")
      end
    end
  end

  describe "the plugin" do
    let(:notices) { [] }
    let(:cards) { [] }
    let(:acts) { [] }
    let(:ctx) do
      Struct.new(:notices, :cards) do
        def notify(text, level: :info) = notices << [text, level]
        def card(**card) = cards << card
      end.new(notices, cards)
    end

    def plugin(settings = {})
      hooks = Hash.new { |h, k| h[k] = [] }
      chi = Object.new
      chi.define_singleton_method(:on) { |event, priority: 100, &block| hooks[event] << block }
      mod::Plugin.new(settings).register(chi)
      hooks
    end

    def fire(hooks, event)
      hooks[event[:type]].each { |block| block.arity == 1 ? block.call(event) : block.call(event, ctx) }
    end

    # One generation streaming +text+ in batches, as StreamWatch fires them.
    def generation(hooks, text, iteration: 1)
      fire(hooks, { type: :before_generation, iteration: iteration })
      text.each_char.each_slice(batch).with_index do |slice, i|
        fire(hooks, { type: :generation_progress, iteration: iteration, thinking: slice.join, text: "",
                      elapsed_ms: (i + 1) * 4000,
                      stop_generation: ->(reason) { acts.push([:stop_generation, reason]).any? },
                      stop_turn: ->(reason) { acts.push([:stop_turn, reason]).any? } })
      end
    end

    let(:looping) { fixture("cycle3.txt").first }

    it "cuts the first loop in a turn with one warn notice, and stops the turn with a card on the second" do
      hooks = plugin
      fire(hooks, { type: :before_turn })

      generation(hooks, looping)

      expect(acts).to eq([[:stop_generation, "its thinking kept repeating itself"]])
      expect(notices).to eq([["thinking repeats itself (3 sentences ×3, 4k chars, 8 s): cut", :warn]])

      generation(hooks, looping, iteration: 2)

      expect(acts.last.first).to eq(:stop_turn)
      expect(acts.last.last).to start_with("the model's thinking kept repeating itself (3 sentences ×3")
      expect(cards.size).to eq(1)
      expect(cards.first).to include(title: "loop-guard stopped the turn", level: :warn)
      expect(cards.first[:body]).to include("- \"Wait, the count of the letter r in the word might be three, not two.\"")
                                .and include("`sampling:` in config.yml")
    end

    it "starts each turn with no loops counted" do
      hooks = plugin
      2.times do
        fire(hooks, { type: :before_turn })
        generation(hooks, looping)
      end

      expect(acts.map(&:first)).to eq(%i[stop_generation stop_generation])
      expect(cards).to be_empty
    end

    it "acts once per generation" do
      hooks = plugin("thinking" => { "action" => "notify" })
      fire(hooks, { type: :before_turn })
      generation(hooks, looping * 3)
      generation(hooks, looping, iteration: 2)

      expect(notices.map(&:first)).to all(start_with("thinking repeats itself (3 sentences ×3"))
      expect(notices.size).to eq(2)
      expect(acts).to be_empty
    end

    it "stops the turn on the first loop with action: stop" do
      hooks = plugin("thinking" => { "action" => "stop" })
      fire(hooks, { type: :before_turn })
      generation(hooks, looping)

      expect(acts.map(&:first)).to eq([:stop_turn])
      expect(cards.size).to eq(1)
    end

    it "registers no stream hooks with watch: false" do
      expect(plugin("thinking" => { "watch" => false }).keys).to contain_exactly(:before_turn, :before_tool_call, :after_tool_call)
      expect(plugin.keys).to include(:before_generation, :generation_progress)
    end

    it "reads its settings, keeping the defaults for bad values" do
      settings = mod::ThinkingWatch.settings("action" => "explode", "similarity" => "0.6", "repeats" => "1",
                                             "min_chars" => "-3", "max_same" => "12")

      expect(settings).to include("action" => "retry", "similarity" => 0.6, "repeats" => 2, "min_chars" => 2000,
                                  "max_same" => 12, "watch" => true)
    end
  end
end
