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
      input.ask("choice> ") do |answers|
        expect(input.prompt_text).to eq("choice> ")
        input << [:line, "2"]
        taken = answers.pop(timeout: 0)
      end

      expect(taken).to eq([:line, "2"])
      expect(input.pop(timeout: 0)).to be_nil
      expect(input.prompt_text).to eq("> ")
    end

    it "puts what was typed at the prompt aside and back once the question closes" do
      reader.typed_text = "half typed"

      input.ask("choice> ") { nil }

      expect(reader.reprompts).to eq([{ prefill: nil }, { prefill: "half typed" }])
    end

    it "leaves the lines submitted before it for the loop" do
      input << [:line, "typed ahead"]

      input.ask("choice> ") { |answers| expect(answers.pop(timeout: 0)).to be_nil }

      expect(input.pop(timeout: 0)).to eq([:line, "typed ahead"])
    end

    it "starts the reader again when Ctrl-D at choice> ended it" do
      reader.typed_text = "kept"
      allow(input).to receive(:start)

      input.ask("choice> ") { reader.alive = false }

      expect(input).to have_received(:start).with(prefill: "kept")
    end
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
end
