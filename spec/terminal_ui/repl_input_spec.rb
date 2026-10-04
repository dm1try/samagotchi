# frozen_string_literal: true

require "samagotchi/terminal_ui"
require_relative "../support/recording_surface"

RSpec.describe Samagotchi::TerminalUI::ReplInput do
  let(:surface) { RecordingSurface.new }
  let(:main_prompt) { ["> "] }
  let(:input) { described_class.new(prompt: -> { main_prompt.first }, read: ->(*) {}, surface: surface) }
  # Stands in for the LineReader: records reprompts, says what is typed.
  let(:reader) do
    Class.new do
      attr_accessor :current, :typed_text, :alive
      attr_reader :reprompts

      def initialize = @reprompts = []
      def alive? = @alive != false
      def reprompt(**options) = @reprompts << options
    end.new
  end

  before { input.instance_variable_set(:@reader, reader) }

  it "hands the lines read to the loop" do
    input << [:line, "hi"] << [:interrupt, nil]

    expect(input.pop(timeout: 0)).to eq([:line, "hi"])
    expect(input.pop(timeout: 0)).to eq([:interrupt, nil])
    expect(input.pop(timeout: 0)).to be_nil
  end

  describe "#ask" do
    it "gives the question the lines submitted while it waits, at its own prompt" do
      taken = nil
      input.ask("? ") do |answers|
        expect(input.prompt_text).to eq("? ")
        input << [:line, "2"]
        taken = answers.pop(timeout: 0)
      end

      expect(taken).to eq([:line, "2"])
      expect(input.pop(timeout: 0)).to be_nil
      expect(input.prompt_text).to eq("> ")
    end

    it "puts what was typed at the prompt aside and back once the question closes" do
      reader.typed_text = "half typed"

      input.ask("? ") { nil }

      expect(reader.reprompts).to eq([{ prefill: nil }, { prefill: "half typed" }])
    end

    it "leaves the lines submitted before it for the loop" do
      input << [:line, "typed ahead"]

      input.ask("? ") { |answers| expect(answers.pop(timeout: 0)).to be_nil }

      expect(input.pop(timeout: 0)).to eq([:line, "typed ahead"])
    end

    it "starts the reader again when Ctrl-D at the question ended it" do
      reader.typed_text = "kept"
      allow(input).to receive(:start)

      input.ask("? ") { reader.alive = false }

      expect(input).to have_received(:start).with(prefill: "kept")
    end
  end

  # Ctrl-D mid-turn closed the prompt (the REPL exits after the turn); a
  # question asked by a line still queued opens it just for the answer.
  it "opens a closed prompt for the question and closes it after" do
    reader.alive = false
    allow(input).to receive(:start) { reader.alive = true }
    allow(input).to receive(:stop)

    input.ask("? ") { expect(input.prompt_text).to eq("? ") }

    expect(input).to have_received(:start).with(no_args)
    expect(input).to have_received(:stop)
    expect(reader.reprompts).to be_empty
  end

  describe "#sync_prompt" do
    it "starts the read again, typed text kept, only when the prompt changed" do
      reader.current = "> "
      input.sync_prompt
      expect(reader.reprompts).to be_empty

      main_prompt[0] = "continue> "
      input.sync_prompt
      expect(reader.reprompts).to eq([{ keep_text: true }])
    end
  end

  # A line typed ahead (or a steer never merged) is the next turn's input:
  # the turn-end warm-up would prefill a prompt that turn replaces.
  describe "#waiting_input?" do
    it "is true with text typed ahead at the open prompt" do
      reader.typed_text = "half typed"

      expect(input.waiting_input?).to be(true)
    end

    it "is false with an empty (or blank) prompt" do
      reader.typed_text = "   "

      expect(input.waiting_input?).to be(false)
    end

    it "is true with a line a turn left over for the next turn" do
      input.during_turn(->(*) {}, leftovers: -> { ["late"] }) { nil }

      expect(input.waiting_input?).to be(true)
    end

    it "is false with no reader and nothing left over" do
      input.instance_variable_set(:@reader, nil)

      expect(input.waiting_input?).to be(false)
    end
  end
end

RSpec.describe Samagotchi::TerminalUI::ReplInput, "#during_turn" do
  let(:input) { described_class.new(prompt: -> { "> " }, read: ->(*) {}, surface: RecordingSurface.new) }

  it "offers each line to the turn first; what it leaves over comes next, before the inbox" do
    taken = []
    input.during_turn(->(line) { line.start_with?("steer") && (taken << line) }, leftovers: -> { ["late"] }) do
      input << [:line, "steer me"] << [:line, "/stats"] << [:interrupt, nil]
    end
    input << [:line, "after"]

    expect(taken).to eq(["steer me"])
    expect(Array.new(4) { input.pop(timeout: 0) })
      .to eq([[:line, "late"], [:line, "/stats"], [:interrupt, nil], [:line, "after"]])
  end
end
