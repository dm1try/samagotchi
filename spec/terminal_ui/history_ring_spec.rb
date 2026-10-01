# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "reline"
require "samagotchi/terminal_ui"
require "samagotchi/prompt_history"

# A running TUI picks up the lines other processes (the web, another TUI)
# added to the shared history: before each main-prompt read, the file's new
# tail joins Reline's ring. What this TUI read but didn't persist (a
# /command, !rollback) stays where it is.
RSpec.describe Samagotchi::TerminalUI::InputSupport, "history ring" do
  let(:host_class) do
    Class.new do
      include Samagotchi::TerminalUI::InputSupport

      def initialize(scratch: false) = @scratch = scratch
      def slash_commands = []
    end
  end
  let(:ui) { host_class.new }

  around do |example|
    saved = Reline::HISTORY.to_a
    Reline::HISTORY.clear
    Dir.mktmpdir("history-ring") do |dir|
      with_env("SAMAGOTCHI_HISTORY_FILE" => File.join(dir, "history.json")) { example.run }
    end
  ensure
    Reline::HISTORY.replace(saved)
  end

  # Reline adds every line it reads to its ring, as readmultiline(_, true) does.
  def type(line)
    allow(Reline).to receive(:readmultiline) do
      Reline::HISTORY << line
      line
    end
    ui.send(:read_prompt_line, "> ")
  end

  # Another process's append; a later mtime so the change is seen at once.
  def elsewhere(line)
    Samagotchi::PromptHistory.append(line)
    future = Time.now + 5
    File.utime(future, future, Samagotchi::PromptHistory.path)
  end

  it "has a line another process appended in the ring at the next read" do
    Samagotchi::PromptHistory.append("old")
    ui.send(:load_persistent_history)

    type("first")
    ui.send(:persist_recent_history, "first")
    elsewhere("from the web")
    type("second")

    expect(Reline::HISTORY.to_a).to eq(["old", "first", "from the web", "second"])
  end

  it "keeps a /command typed earlier in the ring after picking up new lines" do
    ui.send(:load_persistent_history)

    type("/model x")
    elsewhere("from the web")
    type("next")

    expect(Reline::HISTORY.to_a).to eq(["/model x", "from the web", "next"])
  end

  it "doesn't add this TUI's own persisted lines a second time" do
    ui.send(:load_persistent_history)

    type("mine")
    ui.send(:persist_recent_history, "mine")
    type("again")

    expect(Reline::HISTORY.to_a).to eq(%w[mine again])
  end

  it "never touches the ring in a scratch session" do
    scratch = host_class.new(scratch: true)
    scratch.send(:load_persistent_history)
    Reline::HISTORY << "/model x"
    elsewhere("from the web")
    allow(Reline).to receive(:readmultiline).and_return("hi")
    scratch.send(:read_prompt_line, "> ")

    expect(Reline::HISTORY.to_a).to eq(["/model x"])
  end

  describe "interrupted by the reader's Reprompt or Stop" do
    # Pick-up runs inside LineReader's read, where Reprompt and Stop land at
    # once. Blocks it in PromptHistory.entries (after the signature check),
    # raises +error+ into it, then lets it go on.
    def pick_up_interrupted_by(error)
      entered = Queue.new
      release = Queue.new
      calls = 0
      allow(Samagotchi::PromptHistory).to receive(:entries).and_wrap_original do |original|
        calls += 1
        if calls == 1
          entered << true
          release.pop
        end
        original.call
      end
      thread = Thread.new do
        ui.send(:pick_up_history_lines)
        :returned
      rescue error
        :raised
      end
      thread.report_on_exception = false
      entered.pop
      thread.raise(error)
      sleep 0.05
      release << true
      thread.value
    end

    before do
      Samagotchi::PromptHistory.append("old")
      ui.send(:load_persistent_history)
      elsewhere("from the web")
    end

    [Samagotchi::TerminalUI::LineReader::Reprompt, Samagotchi::TerminalUI::LineReader::Stop].each do |error|
      it "lets a #{error.name.split("::").last} through once the ring is up to date" do
        expect(pick_up_interrupted_by(error)).to eq(:raised)
        expect(Reline::HISTORY.to_a).to eq(["old", "from the web"])

        elsewhere("later")
        ui.send(:pick_up_history_lines)
        expect(Reline::HISTORY.to_a).to eq(["old", "from the web", "later"])
      end
    end

    it "still swallows an ordinary error (an unreadable file)" do
      allow(Samagotchi::PromptHistory).to receive(:entries).and_raise(Errno::EACCES)

      expect { ui.send(:pick_up_history_lines) }.not_to raise_error
    end
  end

  it "takes a line whose append failed back out of its own lines" do
    ui.send(:load_persistent_history)
    type("lost")
    allow(Samagotchi::PromptHistory).to receive(:append).and_raise(Errno::ENOSPC)
    ui.send(:persist_recent_history, "lost")
    allow(Samagotchi::PromptHistory).to receive(:append).and_call_original

    expect(ui.send(:history_own_lines)).to be_empty
    elsewhere("lost")
    ui.send(:pick_up_history_lines)
    expect(Reline::HISTORY.to_a).to eq(%w[lost lost])
  end
end
