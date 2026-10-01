# frozen_string_literal: true

require "tmpdir"
require "json"
require "samagotchi/terminal_ui"
require "samagotchi/archive_store"
require_relative "support/recording_surface"

# An archived session comes back to the lists when the user types into it in
# a chi REPL (a prompt, or a headless -p); a continue or a reminder turn
# doesn't bring it back.
RSpec.describe "TerminalUI and archived sessions" do
  let(:state_home) { Dir.mktmpdir("tui-archive-state") }
  let(:client) { instance_double(Samagotchi::Client) }
  let(:surface) { RecordingSurface.new }
  let(:state_dir) { Samagotchi::Session.default_state_dir }
  let(:result) { Samagotchi::LLM::ModelResult.new(text: "done") }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME", "SAMAGOTCHI_HISTORY_FILE")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "gemma4"
    ENV["XDG_STATE_HOME"] = state_home
    ENV["SAMAGOTCHI_HISTORY_FILE"] = File.join(state_home, "history.json")
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME SAMAGOTCHI_HISTORY_FILE].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(state_home)
  end

  let!(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd).tap do |s|
      s.messages = [{ role: "user", content: "earlier" }, { role: "assistant", content: "ok" }]
      s.save
      Samagotchi::ArchiveStore.archive(s.id, state_dir: state_dir)
    end
  end

  def archived? = Samagotchi::ArchiveStore.archived?(Samagotchi::Session.session_dir(session.id))

  def stub_turns(ui)
    engine = ui.engine
    allow(engine).to receive(:run_turn).and_return(result)
  end

  it "a prompt typed in the REPL brings it back; a continue turn doesn't" do
    ui = Samagotchi::TerminalUI.new(client: client, surface: surface, session_id: session.id)
    stub_turns(ui)

    ui.run_engine_turn(session, nil, continue: true)
    expect(archived?).to be(true)

    ui.run_engine_turn(session, "next step")
    expect(archived?).to be(false)
  ensure
    ui&.instance_variable_get(:@owner_lock)&.release
  end

  it "a headless -p on it brings it back" do
    ui = Samagotchi::TerminalUI.new(client: client, surface: surface, session_id: session.id, prompt: "go on",
                                    non_interactive: true)
    stub_turns(ui)

    ui.run

    expect(archived?).to be(false)
  end

  describe "/archive" do
    def repl(**opts)
      Samagotchi::TerminalUI.new(client: client, surface: surface, **opts).tap do |ui|
        allow(ui).to receive(:drain_pending_question?)
        allow(ui).to receive(:recap_after_exit)
      end
    end

    before { Samagotchi::ArchiveStore.unarchive(session.id, state_dir: state_dir) }

    it "leaves the REPL and archives the session" do
      ui = repl(session_id: session.id)
      allow(ui).to receive(:poll_input_with_reminder_check).and_return("/archive")

      ui.run

      expect(archived?).to be(true)
      expect(surface.lines.last).to eq("Archived session #{session.id}. chi sessions list --archived finds it.")
      expect(Samagotchi::SessionManager.session_owner(session.id)).to be_nil
    end

    it "discards an empty session instead" do
      ui = repl
      allow(ui).to receive(:poll_input_with_reminder_check).and_return("/archive")

      ui.run

      expect(surface.lines.last).to eq("The session was empty, so it is discarded.")
      expect(Samagotchi::Session.list(include_archived: true).map(&:id)).to eq([session.id])
    end

    it "is refused in a chi scratch REPL, which goes on and deletes its session at the end" do
      ui = repl(scratch: true)
      allow(ui).to receive(:poll_input_with_reminder_check).and_return("/archive", nil)

      ui.run

      expect(surface.lines).to include("a scratch session is deleted when you leave; nothing to archive")
      expect(surface.lines.last).to eq("Scratch session deleted.")
      expect(Samagotchi::Session.list(include_archived: true).map(&:id)).to eq([session.id])
    end
  end
end
