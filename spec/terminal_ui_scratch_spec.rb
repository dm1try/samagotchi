# frozen_string_literal: true

require "tmpdir"
require "json"
require "samagotchi/terminal_ui"
require_relative "support/recording_surface"

# `chi scratch`: a plain REPL whose session is deleted however it ends. The
# REPL's read is stubbed: nil is what Ctrl-D and Ctrl-C at the prompt give.
RSpec.describe "TerminalUI scratch session" do
  let(:state_home) { Dir.mktmpdir("tui-scratch-state") }
  let(:client) { instance_double(Samagotchi::Client) }
  let(:surface) { RecordingSurface.new }
  let(:state_dir) { Samagotchi::Session.default_state_dir }
  let(:history) { File.join(state_home, "history.json") }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME", "SAMAGOTCHI_HISTORY_FILE")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "gemma4"
    ENV["XDG_STATE_HOME"] = state_home
    ENV["SAMAGOTCHI_HISTORY_FILE"] = history
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME SAMAGOTCHI_HISTORY_FILE].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(state_home)
  end

  def scratch_ui(**opts)
    Samagotchi::TerminalUI.new(client: client, surface: surface, scratch: true, **opts).tap do |ui|
      allow(ui).to receive(:drain_pending_question?)
    end
  end

  # What is on disk for sessions: files and directories.
  def leftovers = Dir.exist?(state_dir) ? Dir.children(state_dir) : []

  # The session file while the REPL runs.
  def saved_record
    path = Dir.glob(File.join(state_dir, "*.json")).first
    path && JSON.parse(File.read(path))
  end

  it "is saved as scratch from the start, says so, and is deleted at /exit with no recap" do
    ui = scratch_ui
    engine = ui.engine
    expect(engine).not_to receive(:write_recap_now)
    on_disk = nil
    allow(ui).to receive(:poll_input_with_reminder_check) do
      on_disk = saved_record
      "/exit"
    end

    ui.run

    expect(on_disk).to include("scratch" => true)
    expect(surface.lines.first).to eq("Scratch session: nothing is kept, it is deleted when you leave.")
    expect(surface.lines.last).to eq("Scratch session deleted.")
    expect(surface.lines.join("\n")).not_to include("Continue session")
    expect(leftovers).to be_empty
    expect(engine.recap).to be_nil
  end

  it "is deleted at Ctrl-D or Ctrl-C at the prompt (no line read), after a turn was saved" do
    ui = scratch_ui
    allow(ui).to receive(:poll_input_with_reminder_check).and_return("hello", nil)
    allow(ui).to receive(:run_input_line) do |session, input|
      ui.send(:persist_recent_history, input)
      session.messages << { role: "user", content: input }
      session.save
    end

    ui.run

    expect(ui).to have_received(:run_input_line).once
    expect(leftovers).to be_empty
    expect(File.exist?(history)).to be(false)
  end

  it "is deleted when the REPL fails, and the error goes on" do
    ui = scratch_ui
    allow(ui).to receive(:poll_input_with_reminder_check).and_raise(RuntimeError, "boom")

    expect { ui.run }.to raise_error(RuntimeError, "boom")
    expect(leftovers).to be_empty
  end

  %w[TERM HUP].each do |signal|
    it "is deleted on SIG#{signal} (Ruby raises it on the main thread), quietly" do
      ui = scratch_ui
      allow(ui).to receive(:poll_input_with_reminder_check).and_raise(SignalException.new(signal))

      expect { ui.run }.to raise_error(SignalException)
      expect(leftovers).to be_empty
      expect(surface.lines).not_to include("Scratch session deleted.")
    end
  end

  it "is deleted after a -p --non-interactive turn, which prints its answer last" do
    ui = scratch_ui(prompt: "Reply with exactly: PONG", non_interactive: true)
    engine = ui.engine
    allow(engine).to receive(:run_turn) do |session, prompt, **|
      session.messages << { role: "user", content: prompt } << { role: "model", content: "PONG" }
      double(output: "PONG")
    end

    ui.run

    expect(surface.lines.last).to eq("PONG")
    expect(leftovers).to be_empty
  end

  it "says how to finish when the delete fails" do
    ui = scratch_ui
    allow(ui).to receive(:poll_input_with_reminder_check).and_return(nil)
    allow(Samagotchi::SessionManager).to receive(:delete_session).and_raise(Errno::EACCES, "sessions")

    expect { ui.run }.to output(/Scratch session \S+ was not deleted \(Permission denied.*chi sessions delete /).to_stderr
  end
end
