# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "reline"
require "samagotchi/terminal_ui"
require "samagotchi/prompt_history"
require "samagotchi/terminal_ui/reline_history_hook"

# The first ↑ of a history walk at an open main prompt picks up the lines
# other processes (the web, another TUI) added since the prompt opened.
# Drives a real Reline::LineEditor (the pinned reline) key by key, the way
# Reline.readmultiline does, with InputSupport's pick-up as the refresh.
RSpec.describe Samagotchi::TerminalUI::RelineHistoryHook do
  let(:host_class) do
    Class.new do
      include Samagotchi::TerminalUI::InputSupport

      def initialize(scratch: false) = @scratch = scratch
      def slash_commands = []
    end
  end
  let(:ui) { host_class.new }
  let(:editor) { Reline::LineEditor.new(Reline.core.config) }

  before do
    allow(Reline::IOGate).to receive_messages(get_screen_size: [10, 30], cursor_pos: Reline::CursorPos.new(0, 0))
    allow(Reline::IOGate).to receive(:write)
    described_class.install
  end

  around do |example|
    saved = Reline::HISTORY.to_a
    Reline::HISTORY.clear
    rspec_trap = Signal.trap("INT", "DEFAULT")
    Signal.trap("INT", rspec_trap)
    editor.instance_variable_set(:@old_trap, rspec_trap)
    Dir.mktmpdir("history-hook") do |dir|
      with_env("SAMAGOTCHI_HISTORY_FILE" => File.join(dir, "history.json")) { example.run }
    end
  ensure
    Signal.trap("INT", rspec_trap)
    Reline::HISTORY.replace(saved)
  end

  def open_prompt(prompt = "> ")
    editor.reset(prompt)
    editor.multiline_on
  end

  def type(text)
    text.each_char { |char| editor.update(Reline::Key.new(char, :ed_insert, false)) }
  end

  # A key in a main-prompt read: the refresh is InputSupport's pick-up.
  def press(method_symbol, char = "", refresh: ui.method(:pick_up_history_lines))
    described_class.with_refresh(refresh) { editor.update(Reline::Key.new(char, method_symbol, false)) }
  end

  # Another process's append; a later mtime so the change is seen at once.
  def elsewhere(line)
    Samagotchi::PromptHistory.append(line)
    future = Time.now + 5
    File.utime(future, future, Samagotchi::PromptHistory.path)
  end

  def start_with(*lines)
    lines.each { |line| Samagotchi::PromptHistory.append(line) }
    ui.send(:load_persistent_history)
    open_prompt
  end

  it "shows a line another process appended after the prompt opened at the first ↑" do
    start_with("old")
    elsewhere("from the web")
    press(:ed_prev_history)

    expect(editor.whole_buffer).to eq("from the web")
  end

  it "doesn't change the ring in the middle of a walk" do
    start_with("a", "b")
    press(:ed_prev_history)
    expect(editor.whole_buffer).to eq("b")

    elsewhere("c")
    press(:ed_prev_history)

    expect(editor.whole_buffer).to eq("a")
    expect(Reline::HISTORY.to_a).to eq(%w[a b])
  end

  it "doesn't read the file when it hasn't changed" do
    start_with("old")
    expect(Samagotchi::PromptHistory).not_to receive(:entries)
    press(:ed_prev_history)

    expect(editor.whole_buffer).to eq("old")
  end

  it "checks nothing in a scratch session" do
    scratch = host_class.new(scratch: true)
    Reline::HISTORY << "old"
    open_prompt
    elsewhere("from the web")
    expect(Samagotchi::PromptHistory).not_to receive(:signature)
    press(:ed_prev_history, refresh: scratch.method(:pick_up_history_lines))

    expect(editor.whole_buffer).to eq("old")
  end

  it "only moves the cursor up off the second line of a multi-line buffer" do
    start_with("old")
    type("x")
    editor.update(Reline::Key.new("\n", :key_newline, false))
    type("y")
    elsewhere("from the web")
    expect(Samagotchi::PromptHistory).not_to receive(:signature)
    press(:ed_prev_history)

    expect(editor.whole_buffer).to eq("x\ny")
    expect(editor.instance_variable_get(:@line_index)).to eq(0)
  end

  it "refreshes for inputrc's previous-history too" do
    start_with("old")
    elsewhere("from the web")
    press(:previous_history)

    expect(editor.whole_buffer).to eq("from the web")
  end

  it "covers ↑, Ctrl-P and vi command k and - (they all run ed_prev_history)" do
    expect(Reline::KeyActor::EMACS_MAPPING[0x10]).to eq(:ed_prev_history)
    expect(Reline::KeyActor::VI_COMMAND_MAPPING.values_at("k".ord, "-".ord, 0x10)).to all(eq(:ed_prev_history))
    expect(Reline::ANSI::ANSI_CURSOR_KEY_BINDINGS["A"].first).to eq(:ed_prev_history)
  end

  it "is plain ↑ in a read with no refresh (a question, a continue prompt)" do
    start_with("old")
    elsewhere("from the web")
    press(:ed_prev_history, refresh: nil)

    expect(editor.whole_buffer).to eq("old")
  end

  it "lets a Reprompt raised in the refresh out of the key" do
    start_with("old")
    reprompt = -> { raise Samagotchi::TerminalUI::LineReader::Reprompt }

    expect { press(:ed_prev_history, refresh: reprompt) }.to raise_error(Samagotchi::TerminalUI::LineReader::Reprompt)
  end

  it "is plain ↑ when the refresh fails" do
    start_with("old")
    press(:ed_prev_history, refresh: -> { raise Errno::EACCES })

    expect(editor.whole_buffer).to eq("old")
  end

  it "checks again on the first ↑ after ↓ back to the bottom" do
    start_with("old")
    press(:ed_prev_history)
    press(:ed_next_history)
    expect(editor.whole_buffer).to eq("")

    elsewhere("new")
    press(:ed_prev_history)

    expect(editor.whole_buffer).to eq("new")
  end

  it "holds for the installed Reline" do
    expect(described_class).to be_supported
  end

  it "is unsupported when a method it overrides is missing or changed" do
    stub_const("#{described_class}::METHODS", described_class::METHODS.merge(prev_history_line: -2))
    expect(described_class).not_to be_supported

    stub_const("#{described_class}::METHODS", { ed_prev_history: 1, previous_history: -2 })
    expect(described_class).not_to be_supported
  end

  it "is installed for each main-prompt read" do
    allow(Reline).to receive(:readmultiline) do
      expect(described_class.refresh).to eq(ui.method(:pick_up_history_lines))
      "hi"
    end
    ui.send(:read_prompt_line, "> ")

    expect(Reline::LineEditor.ancestors).to include(described_class)
    expect(described_class.refresh).to be_nil
  end

  # No Screen, no RelineSeam: plain output (TERM=dumb, a PlainSurface).
  it "works without RelineSeam in Reline" do
    script = <<~RUBY
      require "samagotchi/terminal_ui/reline_history_hook"
      abort "seam loaded" if defined?(Samagotchi::TerminalUI::RelineSeam)
      hook = Samagotchi::TerminalUI::RelineHistoryHook
      hook.install
      Reline::HISTORY << "old"
      editor = Reline::LineEditor.new(Reline.core.config)
      def (Reline::IOGate).get_screen_size = [10, 30]
      def (Reline::IOGate).cursor_pos = Reline::CursorPos.new(0, 0)
      editor.reset("> ")
      hook.with_refresh(-> { Reline::HISTORY << "from the web" }) do
        editor.update(Reline::Key.new("", :ed_prev_history, false))
      end
      print editor.whole_buffer
    RUBY
    lib = File.expand_path("../../lib", __dir__)
    out, status = Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", script, stdin_data: "")

    expect([out, status.success?]).to eq(["from the web", true])
  end
end
