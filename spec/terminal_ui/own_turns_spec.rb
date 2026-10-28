# frozen_string_literal: true

require "samagotchi/terminal_ui/attached_loop"

RSpec.describe Samagotchi::TerminalUI::OwnTurns do
  subject(:turns) { described_class.new(active: active) }

  context "when inactive" do
    let(:active) { false }

    it "remembers sent prompts but ignores turn failures" do
      turns.sent("e1")
      turns.ended("e1", failed: true, empty: true, display_pending: true)
      turns.prompt_failed

      expect(turns.sent?("e1")).to be(true)
      expect(turns.pending?).to be(false)
      expect(turns.outcome).to eq(:detached)
    end
  end

  context "when active" do
    let(:active) { true }

    it "waits for a sent prompt to end" do
      turns.sent("e1")

      expect(turns.pending?).to be(true)
      turns.ended("e1", failed: false, empty: false, display_pending: false)
      expect(turns.pending?).to be(false)
      expect(turns.outcome).to eq(:detached)
    end

    it "fails only when a pending own prompt's turn fails" do
      turns.sent("e1")
      turns.ended("other", failed: true, empty: false, display_pending: false)

      expect(turns.pending?).to be(true)
      expect(turns.outcome).to eq(:detached)

      turns.ended("e1", failed: true, empty: false, display_pending: false)
      expect(turns.outcome).to eq(:turn_failed)
    end

    it "ends merged prompts with the running turn" do
      turns.sent("e1")
      turns.merged("e1")
      turns.ended("other", failed: true, empty: false, display_pending: false)

      expect(turns.pending?).to be(false)
      expect(turns.outcome).to eq(:turn_failed)
    end

    it "reports an empty answer unless a turn failed" do
      turns.sent("e1")
      turns.ended("e1", failed: false, empty: true, display_pending: false)
      expect(turns.outcome).to eq(:empty_answer)

      turns.prompt_failed
      expect(turns.outcome).to eq(:turn_failed)
    end

    it "waits for the answer display" do
      turns.sent("e1")
      turns.ended("e1", failed: false, empty: false, display_pending: true)

      expect(turns.pending?).to be(true)
      turns.displayed
      expect(turns.pending?).to be(false)
    end

    it "tracks commands until they run" do
      turns.command_sent("c1")

      expect(turns.pending?).to be(true)
      turns.end_input
      turns.command_ran("c1")
      expect(turns.input_ended?).to be(true)
      expect(turns.pending?).to be(false)
    end

    it "distinguishes our dequeued prompt from another client's" do
      turns.sent("e1")
      expect(turns.dequeued("e1", by_us: true)).to be(true)
      expect(turns.outcome).to eq(:empty_answer)

      turns.sent("e2")
      expect(turns.dequeued("e2", by_us: false)).to be(true)
      expect(turns.outcome).to eq(:turn_failed)
      expect(turns.dequeued("missing", by_us: false)).to be(false)
    end
  end
end
