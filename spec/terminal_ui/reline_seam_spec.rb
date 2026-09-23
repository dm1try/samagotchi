# frozen_string_literal: true

require "samagotchi/terminal_ui/screen"
require "samagotchi/terminal_ui/reline_seam"
require_relative "../support/virtual_terminal"

# Drives a real Reline::LineEditor (the pinned reline) key by key, the way
# Reline.readmultiline does, with its drawing going through the seam into a
# Screen on a virtual terminal. This is the contract the seam relies on: if a
# Reline update breaks it, these fail.
RSpec.describe Samagotchi::TerminalUI::RelineSeam do
  let(:rows) { 10 }
  let(:term) { VirtualTerminal.new(rows: rows, columns: 30) }
  let(:screen) { Samagotchi::TerminalUI::Screen.new(out: term, size: -> { [term.rows, term.columns] }) }
  let(:editor) { Reline::LineEditor.new(Reline.core.config) }

  before do
    allow(Reline).to receive(:ambiguous_width).and_return(1)
    allow(Reline::IOGate).to receive_messages(get_screen_size: [rows, 30], cursor_pos: Reline::CursorPos.new(0, 7))
    # Reline itself must not write anything while the seam is attached.
    allow(Reline::IOGate).to receive(:write) { |text| raise "Reline wrote #{text.inspect}" }
    described_class.attach(screen)
  end

  # Examples leave their read open; a real read always finalizes.
  after do
    described_class.detach(screen)
    described_class.reading = false
  end

  # LineEditor#finalize puts back the INT trap a read replaced (@old_trap):
  # keep RSpec's own.
  around do |example|
    rspec_trap = Signal.trap("INT", "DEFAULT")
    Signal.trap("INT", rspec_trap)
    editor.instance_variable_set(:@old_trap, rspec_trap)
    example.run
  ensure
    Signal.trap("INT", rspec_trap)
  end

  def open_prompt(prompt = "> ")
    editor.reset(prompt)
    editor.multiline_on
    editor.update_dialogs
    editor.rerender
  end

  def type(text)
    text.each_char do |char|
      editor.update(Reline::Key.new(char, :ed_insert, false))
      editor.rerender
    end
  end

  def press(method_symbol, char = "")
    editor.update(Reline::Key.new(char, method_symbol, false))
    editor.rerender
  end

  it "holds for the installed Reline" do
    expect(described_class).to be_supported
  end

  it "is unsupported when a method it relies on is missing" do
    stub_const("#{described_class}::METHODS", described_class::METHODS.merge(render_rows: 0))

    expect(described_class).not_to be_supported
  end

  it "draws the prompt and the typed text in the editor slot" do
    screen.set_slot(:activity, ["| thinking…"])
    screen.set_slot(:status, ["ctx 12%"])
    open_prompt
    type("hello")

    expect(term.lines).to eq(["| thinking…", "> hello", "ctx 12%"])
    expect(term.cursor).to eq([1, 7])
  end

  it "keeps the typed text in place while output is committed above it" do
    screen.set_slot(:status, ["ctx 12%"])
    open_prompt
    type("abc")

    screen.commit("model> #{"streamed " * 6}")
    type("d")

    expect(term.lines.last(2)).to eq(["> abcd", "ctx 12%"])
    expect(term.cursor).to eq([term.lines.size - 2, 6])
  end

  it "opens the completion dialog below the prompt, above the status row" do
    Reline.autocompletion = true
    screen.set_slot(:status, ["ctx 12%"])
    open_prompt
    editor.completion_proc = ->(word) { %w[/model /models /stats].select { |c| c.start_with?(word) } }
    editor.add_dialog_proc(:autocomplete, Reline::DEFAULT_DIALOG_PROC_AUTOCOMPLETE, Reline::DEFAULT_DIALOG_CONTEXT)
    type("/mo")

    expect(term.lines.map(&:strip)).to eq(["> /mo", "/model", "/models", "ctx 12%"])
  ensure
    Reline.autocompletion = false
  end

  # Reline decides between below and above from the cursor row the terminal
  # reported (7 of 10 here); the region has room below.
  it "opens the dialog below a later line of the input too" do
    Reline.autocompletion = true
    open_prompt
    editor.completion_proc = ->(word) { %w[/model /models].select { |c| c.start_with?(word) } }
    editor.add_dialog_proc(:autocomplete, Reline::DEFAULT_DIALOG_PROC_AUTOCOMPLETE, Reline::DEFAULT_DIALOG_CONTEXT)
    type("a")
    press(:key_newline, "\n")
    type("b")
    press(:key_newline, "\n")
    type("/mo")

    expect(term.lines.map(&:strip)).to eq(["> a", "> b", "> /mo", "/model", "/models"])
  ensure
    Reline.autocompletion = false
  end

  it "moves a submitted prompt to scrollback" do
    screen.set_slot(:status, ["ctx 12%"])
    open_prompt
    type("hi")

    editor.render_finished
    editor.finalize

    expect(term.lines).to eq(["> hi", "ctx 12%"])
    expect(term.cursor).to eq([2, 0])
  end

  it "takes the prompt of a dropped read out of the region" do
    screen.set_slot(:status, ["ctx 12%"])
    open_prompt
    type("half typed")

    editor.finalize

    expect(term.lines).to eq(["ctx 12%"])
  end

  it "leaves the text with ^C on Ctrl-C and raises Interrupt as Reline does" do
    open_prompt
    type("oops")
    # Ctrl-C during a read: Reline's trap set @interrupted, and the trap it
    # replaced was the default one.
    editor.instance_variable_set(:@old_trap, "DEFAULT")
    editor.instance_variable_set(:@interrupted, true)

    expect { editor.send(:handle_interrupted) }.to raise_error(Interrupt)
    editor.finalize
    expect(term.lines).to eq(["> oops^C"])
  end

  describe "Ctrl-C with an interrupt handler" do
    after { described_class.interrupt_handler = nil }

    def ctrl_c
      editor.instance_variable_set(:@old_trap, "DEFAULT")
      editor.instance_variable_set(:@interrupted, true)
      editor.send(:handle_interrupted)
    end

    it "keeps the read and the typed text when the handler takes it" do
      calls = 0
      described_class.interrupt_handler = -> { (calls += 1).positive? }
      screen.set_slot(:status, ["ctx 12%"])
      open_prompt
      type("half")

      expect { ctrl_c }.not_to raise_error
      type(" more")

      expect(calls).to eq(1)
      expect(term.lines).to eq(["> half more", "ctx 12%"])
    end

    it "is Reline's Ctrl-C when the handler declines" do
      described_class.interrupt_handler = -> { false }
      open_prompt
      type("oops")

      expect { ctrl_c }.to raise_error(Interrupt)
      editor.finalize
      expect(term.lines).to eq(["> oops^C"])
    end

    it "asks the handler with no screen attached too" do
      described_class.detach(screen)
      allow(Reline::IOGate).to receive(:write)
      described_class.interrupt_handler = -> { true }
      open_prompt
      type("x")

      expect { ctrl_c }.not_to raise_error
      expect(editor.line).to eq("x")
    end
  end

  it "knows when a read is open" do
    expect(described_class).not_to be_reading
    open_prompt
    expect(described_class).to be_reading
    editor.finalize
    expect(described_class).not_to be_reading
  end

  it "clears the screen on Ctrl-L and draws the prompt at the top" do
    screen.commit("old output")
    screen.set_slot(:status, ["ctx 12%"])
    open_prompt
    type("x")

    press(:ed_clear_screen, "\C-l")

    expect(term.lines).to eq(["> x", "ctx 12%"])
  end

  describe "a prompt taller than the room left for it" do
    let(:rows) { 6 }

    it "scrolls the input inside the editor rows and keeps the activity and status rows" do
      screen.set_slot(:activity, ["| thinking…"])
      screen.set_slot(:status, ["ctx 12%"])
      screen.set_slot(:hints, ["? for help"])
      open_prompt
      %w[one two three four five].each_with_index do |word, i|
        press(:key_newline, "\n") if i.positive?
        type(word)
      end

      expect(term.lines).to eq(["| thinking…", "> three", "> four", "> five", "ctx 12%"])
      expect(term.cursor).to eq([3, 6])

      press(:ed_prev_history)
      press(:ed_prev_history)
      press(:ed_prev_history)
      expect(term.lines[1]).to eq("> two")
    end
  end

  it "leaves Reline's own drawing alone with no screen attached" do
    described_class.detach(screen)
    written = +""
    allow(Reline::IOGate).to receive(:write) { |text| written << text }

    open_prompt
    type("x")

    expect(written).to include("> ", "x")
    expect(term.lines).to be_empty
  end
end
