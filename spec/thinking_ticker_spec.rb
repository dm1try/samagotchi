# frozen_string_literal: true

require "spec_helper"
require "samagotchi/thinking_ticker"

# The cases of spec/web/public/thinking_ticker.test.js: the terminal and the
# web must pick the same sentence.
RSpec.describe Samagotchi::ThinkingTicker do
  describe ".current_sentence" do
    def current(text) = described_class.current_sentence(text)

    it "is empty with no boundary yet" do
      expect(current("")).to eq("")
      expect(current("   ")).to eq("")
      expect(current("just some words flowing")).to eq("")
    end

    it "takes a quote or bracket after the period" do
      expect(current("Hello world.")).to eq("Hello world.")
      expect(current('She said "stop."')).to eq('She said "stop."')
      expect(current("The result (42) is ready.")).to eq("The result (42) is ready.")
    end

    it "splits at a newline" do
      expect(current("line one\nline two")).to eq("line one")
      expect(current("line one\nline two\n")).to eq("line two")
    end

    it "reads a bare list number as a marker, not a sentence" do
      expect(current("Plan:\n1. check the log\n2. write it up\n")).to eq("2. write it up")
      expect(current("1. check the log\n2. write")).to eq("1. check the log")
      expect(current("Recent:\n118. `d48e707` - Attached TUI stays up\n119. `x` - next"))
        .to eq("118. `d48e707` - Attached TUI stays up")
      expect(current("Recent:\n118. ")).to eq("Recent:")
      expect(current("It took 3. Then more.")).to eq("Then more.")
    end

    it "ends a sentence at an ellipsis" do
      expect(current("Wait… then act.")).to eq("then act.")
      expect(current("Wait…")).to eq("Wait…")
    end

    it "picks the newest, collapsed and trimmed" do
      expect(current("First. Second. Third.")).to eq("Third.")
      expect(current("Hello    world.\n\n  This is  a test.  ")).to eq("This is a test.")
      expect(current("Done. Next one.")).to eq("Next one.")
    end

    it "takes a fragment longer than MAX_LEN" do
      expect(current("x" * 160)).to eq("")
      expect(current("x" * 161)).to eq("x" * 161)
    end
  end

  describe "the ticker" do
    let(:now) { [100.0] }
    let(:ticker) { described_class.new(clock: -> { now[0] }) }

    it "shows the first sentence at once and keeps an unchanged one" do
      expect(ticker.feed("no boundary")).to be(false)
      expect(ticker.feed("One. ")).to be(true)
      expect(ticker.line).to eq("One.")
      expect(ticker.feed("One. Two")).to be(false)
    end

    it "holds a line for the dwell, then jumps to the newest sentence" do
      ticker.feed("One. ")
      now[0] += 0.5
      expect(ticker.feed("One. Two. ")).to be(false)
      expect(ticker.feed("One. Two. Three. ")).to be(false)
      expect(ticker.line).to eq("One.")
      now[0] += 0.9
      expect(ticker.tick).to be(false)
      now[0] += 0.1
      expect(ticker.tick).to be(true)
      expect(ticker.line).to eq("Three.")
      expect(ticker.tick).to be(false)
    end

    it "shows a new sentence at once when the dwell is long over" do
      ticker.feed("One. ")
      now[0] += 5
      expect(ticker.feed("One. Two. ")).to be(true)
      expect(ticker.line).to eq("Two.")
    end

    it "drops a pending line that the shown one caught up with" do
      ticker.feed("One. ")
      ticker.feed("One. Two. ")
      ticker.feed("One. Two. One. ")
      now[0] += 2
      expect(ticker.tick).to be(false)
      expect(ticker.line).to eq("One.")
    end

    it "starts over on reset" do
      ticker.feed("One. ")
      ticker.reset
      expect(ticker.line).to eq("")
      expect(ticker.feed("Two. ")).to be(true)
    end
  end
end
