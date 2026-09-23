# frozen_string_literal: true

require "stringio"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_screen"

RSpec.describe Samagotchi::TerminalUI::AttachedScreen do
  # Stands in for Reline's line editor: whether a prompt is on screen, the
  # cursor's row inside it, and the redraws the screen asks for.
  let(:canvas) do
    Struct.new(:drawn, :cursor_y, :redraws) do
      def drawn? = drawn
      def redraw! = self.redraws += 1
      def forget_rendered! = self.drawn = false
    end.new(false, 0, 0)
  end
  let(:out) { StringIO.new }
  let(:screen) { described_class.new(out: out, canvas: canvas, width: -> { 20 }) }

  def written
    text = out.string.dup
    out.truncate(0)
    out.rewind
    text
  end

  context "with no prompt on screen" do
    it "prints lines as they come" do
      screen.commit("hello")
      screen.commit("two\nlines")

      expect(written).to eq("\r\e[Jhello\r\n\r\e[Jtwo\r\nlines\r\n")
    end

    it "keeps one status line under the output, replacing it on each change" do
      screen.set_slot(:activity, ["thinking"])
      expect(written).to eq("\r\e[Jthinking\r\n")

      screen.commit("tool> read")
      expect(written).to eq("\e[1A\r\e[Jtool> read\r\nthinking\r\n")

      screen.clear_slot(:activity)
      expect(written).to eq("\e[1A\r\e[J")
    end

    it "says whether clearing the status line erased one" do
      expect(screen.clear_slot(:activity)).to be(false)

      screen.set_slot(:activity, ["thinking"])

      expect(screen.clear_slot(:activity)).to be(true)
    end

    it "prints the notes slot's rows as output, with nothing left to clear" do
      screen.set_slot(:notes, ["? Which one?", "  1) Apple"])

      expect(written).to eq("\r\e[J? Which one?\r\n\r\e[J  1) Apple\r\n")
      expect(screen.clear_slot(:notes)).to be(false)
      expect(written).to eq("")
    end
  end

  context "with a prompt on screen" do
    before do
      canvas.drawn = true
      canvas.cursor_y = 1
    end

    it "moves over the prompt, prints above it, and has the prompt redrawn" do
      screen.commit("event")

      expect(written).to eq("\e[1A\r\e[Jevent\r\n")
      expect(canvas.redraws).to eq(1)
    end

    it "also moves over the status line" do
      screen.set_slot(:activity, ["thinking"])
      written

      screen.commit("event")

      expect(written).to eq("\e[2A\r\e[Jevent\r\nthinking\r\n")
      expect(canvas.redraws).to eq(2)
    end

    it "erases the status line before the prompt's final line is written" do
      screen.set_slot(:activity, ["thinking"])
      written

      screen.prompt_finishing(cursor_y: 1)

      expect(written).to eq("\e[2A\r\e[J")
      # The turn is still running: the status line comes back under the next output.
      screen.commit("next")
      expect(written).to eq("\r\e[Jnext\r\nthinking\r\n")
    end

    it "erases the prompt Reline drew when the editor slot is cleared" do
      expect(screen.clear_slot(:editor)).to be(true)

      expect(written).to eq("\e[1A\r\e[J")
      expect(canvas.drawn).to be(false)
      expect(screen.clear_slot(:editor)).to be(false)
    end
  end

  it "leaves the editor slot to Reline and rejects unknown slots" do
    expect { screen.set_slot(:editor, ["> "]) }.to raise_error(ArgumentError, /Reline draws/)
    expect { screen.set_slot(:banner, ["x"]) }.to raise_error(ArgumentError, /unknown slot/)
  end

  it "cuts the status to the terminal width so it never wraps" do
    screen.set_slot(:activity, ["x" * 50])

    expect(written).to eq("\r\e[J#{"x" * 19}\r\n")
  end
end
