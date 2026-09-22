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
      screen.print_line("hello")
      screen.print_line("two\nlines")

      expect(written).to eq("\r\e[Jhello\r\n\r\e[Jtwo\r\nlines\r\n")
    end

    it "keeps one status line under the output, replacing it on each change" do
      screen.status = "thinking"
      expect(written).to eq("\r\e[Jthinking\r\n")

      screen.print_line("tool> read")
      expect(written).to eq("\e[1A\r\e[Jtool> read\r\nthinking\r\n")

      screen.status = nil
      expect(written).to eq("\e[1A\r\e[J")
    end
  end

  context "with a prompt on screen" do
    before do
      canvas.drawn = true
      canvas.cursor_y = 1
    end

    it "moves over the prompt, prints above it, and has the prompt redrawn" do
      screen.print_line("event")

      expect(written).to eq("\e[1A\r\e[Jevent\r\n")
      expect(canvas.redraws).to eq(1)
    end

    it "also moves over the status line" do
      screen.status = "thinking"
      written

      screen.print_line("event")

      expect(written).to eq("\e[2A\r\e[Jevent\r\nthinking\r\n")
      expect(canvas.redraws).to eq(2)
    end

    it "erases the status line before the prompt's final line is written" do
      screen.status = "thinking"
      written

      screen.prompt_finishing(cursor_y: 1)

      expect(written).to eq("\e[2A\r\e[J")
      # The turn is still running: the status line comes back under the next output.
      screen.print_line("next")
      expect(written).to eq("\r\e[Jnext\r\nthinking\r\n")
    end
  end

  it "cuts the status to the terminal width so it never wraps" do
    screen.status = "x" * 50

    expect(written).to eq("\r\e[J#{"x" * 19}\r\n")
  end
end
