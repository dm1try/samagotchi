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
end
