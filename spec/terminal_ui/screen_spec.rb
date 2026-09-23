# frozen_string_literal: true

require "stringio"
require "timeout"
require "samagotchi/terminal_ui/screen"
require_relative "../support/virtual_terminal"

RSpec.describe Samagotchi::TerminalUI::Screen do
  let(:term) { VirtualTerminal.new(rows: 10, columns: 20) }
  let(:screen) { described_class.new(out: term, size: -> { [term.rows, term.columns] }) }

  # Reline asks the terminal how wide ambiguous characters are the first time
  # it measures one; never let a spec write that probe to a real terminal.
  before { allow(Reline).to receive(:ambiguous_width).and_return(1) }

  # Reline's rows for a one-line prompt: [x, width, content] layers.
  def prompt_row(prompt, input) = [[0, prompt.length, prompt], [prompt.length, input.length, input]]

  def cursor = term.cursor

  it "commits text line by line, with nothing else on screen" do
    screen.commit("hello")
    screen.commit("two\nlines")

    expect(term.lines).to eq(%w[hello two lines])
    expect(cursor).to eq([3, 0])
  end

  it "draws the slots around the prompt in order and leaves the cursor in the prompt" do
    screen.set_slot(:hints, ["? for help"])
    screen.set_slot(:status, ["ctx 12%"])
    screen.set_slot(:notes, ["1) Apple"])
    screen.set_slot(:activity, ["| thinking…"])
    screen.draw_editor([prompt_row("> ", "abc")], 5, 0)

    expect(term.lines).to eq(["| thinking…", "> abc", "ctx 12%", "1) Apple", "? for help"])
    expect(cursor).to eq([1, 5])
  end

  it "commits output above the region, which follows it down" do
    screen.set_slot(:activity, ["| thinking…"])
    screen.set_slot(:status, ["ctx 12%"])
    screen.draw_editor([prompt_row("> ", "ab")], 4, 0)

    screen.commit("model> first")
    screen.commit("model> second")

    expect(term.lines).to eq(["model> first", "model> second", "| thinking…", "> ab", "ctx 12%"])
    expect(cursor).to eq([3, 4])
  end

  it "keeps the region in place however far committed text wraps" do
    screen.set_slot(:activity, ["| model> … #{"t" * 20}"])
    screen.set_slot(:status, ["ctx 12%"])
    screen.draw_editor([prompt_row("> ", "")], 2, 0)

    5.times { |i| screen.commit("#{i}: #{"x" * 45}") }

    # Each commit takes 3 rows; 15 rows scrolled through a 10-row screen.
    expect(term.lines.last(3)).to eq(["| model> … #{"t" * 9}", ">", "ctx 12%"])
    expect((term.scrollback + term.lines).grep(/model>|ctx/).size).to eq(2)
    expect(cursor).to eq([8, 2])
  end

  it "clips slot rows to the width, so they never wrap" do
    screen.set_slot(:activity, ["a" * 30])
    screen.set_slot(:status, ["s\tt\nu"])

    expect(term.lines).to eq(["a" * 20, "s t u"])
  end

  it "replaces a slot's rows and says whether clearing erased any" do
    screen.set_slot(:activity, ["| one"])
    screen.set_slot(:activity, ["/ two"])
    expect(term.lines).to eq(["/ two"])

    expect(screen.clear_slot(:activity)).to be(true)
    expect(term.lines).to be_empty
    expect(screen.clear_slot(:activity)).to be(false)
  end

  it "treats setting empty rows as clearing the slot" do
    screen.set_slot(:notes, ["1) Apple"])
    screen.set_slot(:notes, [])

    expect(term.lines).to be_empty
    expect(screen.clear_slot(:notes)).to be(false)
  end

  it "changes several slots in one frame" do
    out = StringIO.new
    both = described_class.new(out: out, size: -> { [10, 20] })

    both.set_slots(activity: ["| thinking"], status: ["ctx 12%"])
    both.set_slots(activity: ["/ thinking"], status: ["ctx 12%"])
    both.set_slots(activity: ["/ thinking"], status: ["ctx 12%"])

    expect(out.string.scan("\e[?2026h").size).to eq(2)
    expect(out.string).to end_with("/ thinking\r\nctx 12%\r\n\e[?25h\e[?2026l")
  end

  it "clears a slot set to no rows in the same frame" do
    screen.set_slots(activity: ["| thinking"], status: ["ctx 12%"])
    screen.set_slots(activity: ["/ thinking"], status: [])

    expect(term.lines).to eq(["/ thinking"])
    expect { screen.set_slots(editor: ["> "]) }.to raise_error(ArgumentError, /Reline draws/)
  end

  it "leaves the editor slot to Reline and rejects unknown slots" do
    expect { screen.set_slot(:editor, ["> "]) }.to raise_error(ArgumentError, /Reline draws/)
    expect { screen.set_slot(:banner, ["x"]) }.to raise_error(ArgumentError, /unknown slot/)
  end

  describe "the editor" do
    it "lays a completion dialog over the rows below the prompt" do
      screen.set_slot(:status, ["ctx 12%"])
      screen.draw_editor([prompt_row("> ", "/mo"), [nil, nil, [2, 7, "/model "]], [nil, nil, [2, 7, "/models"]]], 5, 0)

      expect(term.lines).to eq(["> /mo", "  /model", "  /models", "ctx 12%"])
      expect(cursor).to eq([0, 5])
    end

    it "moves the submitted text to scrollback and keeps the other slots" do
      screen.set_slot(:activity, ["| thinking…"])
      screen.set_slot(:status, ["ctx 12%"])
      screen.draw_editor([prompt_row("> ", "hi")], 4, 0)

      expect(screen.finish_editor(["> hi"])).to be(true)

      expect(term.lines).to eq(["> hi", "| thinking…", "ctx 12%"])
      expect(cursor).to eq([3, 0])
    end

    it "drops a prompt whose read ended without a line, with nothing left behind" do
      screen.set_slot(:status, ["ctx 12%"])
      screen.draw_editor([prompt_row("> ", "typed")], 7, 0)

      expect(screen.clear_slot(:editor)).to be(true)
      expect(term.lines).to eq(["ctx 12%"])
      expect(screen.clear_slot(:editor)).to be(false)
    end

    it "follows the cursor to another row of a multi-line input" do
      screen.set_slot(:activity, ["| thinking…"])
      screen.draw_editor([prompt_row("> ", "one"), prompt_row("  ", "two")], 3, 1)
      screen.commit("out")

      expect(term.lines).to eq(["out", "| thinking…", "> one", "  two"])
      expect(cursor).to eq([3, 3])
    end
  end

  describe "a short terminal" do
    let(:term) { VirtualTerminal.new(rows: 6, columns: 20) }

    before do
      screen.set_slot(:activity, ["| thinking…"])
      screen.set_slot(:status, ["ctx 12%"])
      screen.set_slot(:notes, ["1) Apple"])
      screen.set_slot(:hints, ["? for help"])
    end

    it "gives the editor the rows left after the activity and status rows" do
      expect(screen.editor_budget).to eq(3)
    end

    it "drops the hints, then the notes, when the editor needs the rows" do
      screen.draw_editor([prompt_row("> ", "1"), prompt_row("  ", "2")], 3, 1)
      expect(term.lines).to eq(["| thinking…", "> 1", "  2", "ctx 12%", "1) Apple"])

      screen.draw_editor([prompt_row("> ", "1"), prompt_row("  ", "2"), prompt_row("  ", "3")], 3, 2)
      expect(term.lines).to eq(["| thinking…", "> 1", "  2", "  3", "ctx 12%"])

      screen.commit("out")
      expect(term.lines).to eq(["out", "| thinking…", "> 1", "  2", "  3", "ctx 12%"])
      expect(term.scrollback).to be_empty
    end
  end

  it "clears the screen and draws the region at the top (Ctrl-L)" do
    screen.commit("old output")
    screen.set_slot(:status, ["ctx 12%"])
    screen.draw_editor([prompt_row("> ", "x")], 3, 0)

    screen.clear_screen

    expect(term.lines).to eq(["> x", "ctx 12%"])
    expect(cursor).to eq([0, 3])
  end

  it "erases the whole region on close" do
    screen.commit("kept")
    screen.set_slot(:activity, ["| thinking…"])
    screen.draw_editor([prompt_row("> ", "x")], 3, 0)

    screen.close

    expect(term.lines).to eq(["kept"])
    expect(cursor).to eq([1, 0])
  end

  describe "#start" do
    around do |example|
      stderr = $stderr
      winch = Signal.trap("WINCH", "DEFAULT")
      Signal.trap("WINCH", winch)
      example.run
    ensure
      $stderr = stderr
      Signal.trap("WINCH", winch)
    end

    it "puts what background threads warn above the region" do
      screen.start
      screen.set_slot(:status, ["ctx 12%"])
      screen.draw_editor([prompt_row("> ", "typing")], 8, 0)

      Thread.new { warn "[hook] slow" }.join
      $stderr.print("no newline yet")
      expect(term.lines).to eq(["[hook] slow", "> typing", "ctx 12%"])

      screen.close
      expect(term.lines).to eq(["[hook] slow", "no newline yet"])
    end

    it "gives $stderr and the WINCH trap back on close" do
      stderr = $stderr
      screen.start
      screen.close

      expect($stderr).to be(stderr)
      expect(Signal.trap("WINCH", "DEFAULT")).not_to be_a(Proc)
    end

    it "redraws the region when the terminal is resized outside a read" do
      screen.start
      screen.set_slot(:status, ["ctx 12%"])
      redrawn = Queue.new
      allow(screen).to receive(:redraw).and_wrap_original { |original| original.call.tap { redrawn << true } }

      Process.kill("WINCH", Process.pid)

      expect(Timeout.timeout(2) { redrawn.pop }).to be(true)
      screen.close
    end
  end

  it "wraps each frame in synchronized output with the cursor hidden" do
    out = StringIO.new
    described_class.new(out: out, size: -> { [10, 20] }).commit("hi")

    expect(out.string).to start_with("\e[?2026h\e[?25l").and end_with("\e[?25h\e[?2026l")
  end

  it "finishes a frame even when the thread is interrupted" do
    out = StringIO.new
    slow = described_class.new(out: out, size: -> { [10, 20] })
    started = Queue.new
    allow(out).to receive(:write).and_wrap_original do |original, bytes|
      started << true
      sleep 0.1
      original.call(bytes)
    end
    thread = Thread.new do
      slow.commit("whole")
    rescue RuntimeError
      nil
    end
    started.pop
    thread.raise(RuntimeError, "dropped")
    thread.join

    expect(out.string).to include("whole").and end_with("\e[?2026l")
  end

  # The REPL's reminder poll kills its reader thread (Thread#kill) when a
  # raise didn't stop it; a frame must not be cut short by that either.
  it "finishes a frame even when the thread is killed" do
    out = StringIO.new
    slow = described_class.new(out: out, size: -> { [10, 20] })
    started = Queue.new
    allow(out).to receive(:write).and_wrap_original do |original, bytes|
      started << true
      sleep 0.1
      original.call(bytes)
    end
    thread = Thread.new { slow.commit("whole") }
    started.pop
    thread.kill
    thread.join

    expect(out.string).to include("whole").and end_with("\e[?2026l")
  end
end
