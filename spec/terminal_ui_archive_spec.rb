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
  let(:result) { instance_double(Samagotchi::KernelLoop::Result, output: "done", canceled?: false) }

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
    engine = ui.instance_variable_get(:@engine)
    allow(engine).to receive(:run_turn).and_return(result)
    allow(ui).to receive(:emit_cancellation_notice)
  end

  it "a prompt typed in the REPL brings it back; a continue turn doesn't" do
    ui = Samagotchi::TerminalUI.new(client: client, surface: surface, session_id: session.id)
    stub_turns(ui)

    ui.send(:run_engine_turn, session, nil, continue: true)
    expect(archived?).to be(true)

    ui.send(:run_engine_turn, session, "next step")
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
end
